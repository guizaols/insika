# frozen_string_literal: true

require "spec_helper"
require "async"

# WHAT REACHES THE CUSTOMER (P19). Every chunk the model streams used to become a
# `:content` delta, and `/v1/responses` translates every one of those straight to
# the end customer. Running a real store's 28 KB prompt proved the cost: when the
# model had no tool to call it reasoned in prose, and 132 deltas of an English
# monologue ("Let me check the tools I actually have… Actually, let me reconsider.")
# went out as `response.output_text.delta` — on WhatsApp, that IS the message.
#
# The rule these specs pin: `:content` carries the ANSWER — the text of the assistant
# message that ENDS the turn. Everything else rides `:intermediate`, which the Studio
# and the trace show and the edge drops (see server/responses_spec).
RSpec.describe "Insika::Executor turn output (P19)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  def build_executor(**over)
    defaults = {
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    }
    Insika::Executor.new(**defaults.merge(over))
  end

  def make_task(message: "oi")
    command = Insika::Command.build(:send_message, { agent: "sales", message: message })
    task_store.create(command: command.to_h, session_id: "s1", id: "t")
  end

  def run_turn(executor, chat)
    allow(executor).to receive(:create_chat).and_return(chat)
    task = make_task
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  def deltas(type) = event_stream.events.select { |e| e.type == type }.map { |e| e.data[:delta] }

  def terminal_content
    event_stream.events.find { |e| e.type == :task_completed }&.data&.[](:content)
  end

  before { session_store.create(id: "s1") }

  describe "narration around a tool call" do
    # Finding 3 of the production read: the customer received "Deixa eu buscar
    # opções pra você." AND "Ih, me desculpa! A ferramenta deu uma engasgada" as two
    # messages before the actual answer. Both are the loop talking to itself.
    let(:chat) do
      chat = FakeChat.new
      chat.final_content = "Achei três vestidos midi."
      chat.script = proc do
        emit_chunk("Deixa eu buscar opções pra você.")
        fire_tool_call(name: "search_products", arguments: { "q" => "vestido" })
        fire_tool_result("[]")
      end
      chat
    end

    it "publishes ONLY the answer as :content" do
      run_turn(build_executor, chat)

      expect(deltas(:content)).to eq(["Achei três vestidos midi."])
    end

    it "keeps the narration on :intermediate, where the operator can still read it" do
      run_turn(build_executor, chat)

      expect(deltas(:intermediate)).to include("Deixa eu buscar opções pra você.")
    end

    it "the terminal content is the answer, not the answer plus the narration" do
      run_turn(build_executor, chat)

      expect(terminal_content).to eq("Achei três vestidos midi.")
    end
  end

  describe "the answer" do
    it "is published ONCE, whole, however many chunks it took" do
      chat = FakeChat.new
      chat.final_content = "Temos sim!"
      chat.script = proc do
        emit_chunk("Temos ")
        emit_chunk("sim!")
      end

      run_turn(build_executor, chat)

      # Per-token streaming moved to :intermediate; the customer-visible stream is
      # per MESSAGE. The consumer accumulates deltas either way, so the text it
      # assembles is unchanged — it just stops being able to read half a sentence.
      expect(deltas(:content)).to eq(["Temos sim!"])
      expect(deltas(:intermediate)).to eq(["Temos ", "sim!"])
    end

    it "an empty answer emits no :content at all — nothing to deliver" do
      chat = FakeChat.new
      chat.final_content = ""

      run_turn(build_executor, chat)

      expect(event_stream.types).not_to include(:content)
      expect(terminal_content).to eq("")
    end
  end

  describe "a turn that dies mid-message" do
    it "publishes nothing: half a sentence was never an answer" do
      chat = FakeChat.new
      chat.script = proc do
        emit_chunk("Claro! O prazo de entrega é de")
        raise Insika::TimeoutError.new("turn timeout", stage: :turn)
      end

      run_turn(build_executor, chat)

      expect(event_stream.types).to include(:task_failed)
      expect(event_stream.types).not_to include(:content)
      # ...and the fragment is still on the stream for whoever is debugging it.
      expect(deltas(:intermediate)).to eq(["Claro! O prazo de entrega é de"])
    end
  end

  # PR #130. A data-tool with `halt_when` already answered the customer, so the turn
  # is worth exactly the model's lead-in — which under this mechanism is intermediate
  # text. It is the one case where narration IS the turn, and the halt branch
  # publishes it deliberately.
  describe "halt_when (the exception that proves the rule)" do
    it "publishes the lead-in of the message that called the tool" do
      chat = FakeChat.new
      chat.script = proc { emit_chunk("vou te inscrever agora") }
      chat.halt_with!('{"tool_result":{"status":"SUBSCRIBED"}}')

      run_turn(build_executor, chat)

      expect(deltas(:content)).to eq(["vou te inscrever agora"])
      expect(terminal_content).to eq("vou te inscrever agora")
    end

    it "never the tool payload" do
      chat = FakeChat.new
      chat.script = proc { emit_chunk("vou te inscrever agora") }
      chat.halt_with!('{"tool_result":{"status":"SUBSCRIBED"}}')

      run_turn(build_executor, chat)

      expect(terminal_content).not_to include("SUBSCRIBED")
    end
  end

  describe "an :agent after-hook that replaces the response" do
    it "wins over what the model streamed — an explicit override is not narration" do
      hooks = Insika::Hooks.new
      hooks.register(:agent, after: ->(_r) { FakeChat::Response.new("SUBSTITUÍDO") })
      chat = FakeChat.new
      chat.final_content = "o que o modelo disse"

      run_turn(build_executor(hooks: hooks), chat)

      expect(deltas(:content)).to eq(["SUBSTITUÍDO"])
      expect(terminal_content).to eq("SUBSTITUÍDO")
    end
  end

  # The floor: a transport that never reports a message boundary must still deliver
  # an answer. Everything above depends on `after_message`; this is what happens
  # without it, and it is the pre-P19 behaviour.
  describe "a chat that does not report message boundaries" do
    it "publishes the response content at the end of the turn" do
      chat = FakeChat.new
      allow(chat).to receive(:respond_to?).and_call_original
      allow(chat).to receive(:respond_to?).with(:after_message).and_return(false)
      # Streamed text and response content deliberately DIFFER, so the assertion can
      # only pass through the fallback: with a boundary the answer would be the
      # streamed "narração solta".
      chat.final_content = "resposta"
      chat.script = proc { emit_chunk("narração solta") }

      run_turn(build_executor, chat)

      expect(deltas(:content)).to eq(["resposta"])
      expect(deltas(:intermediate)).to eq(["narração solta"])
    end
  end
end
