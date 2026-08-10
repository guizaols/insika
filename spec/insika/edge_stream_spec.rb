# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../lib/insika/server/responses"

# `edge_stream` — which internal channels an agent lets cross to the CUSTOMER.
#
# The engine holds two back by default: `:thinking` (the provider's reasoning) and
# `:intermediate` (the model narrating its tool loop, or reasoning in prose when it
# has no tool to call). That default exists because a real store's prompt sent 132
# deltas of an English monologue to what would have been a WhatsApp customer.
#
# But "never" is the wrong answer for a product with a thinking panel, so it is the
# operator's call per agent. Two invariants make that safe rather than a re-opened
# hole: nothing crosses unless someone opted in, and what crosses gets its OWN frame
# type — never the answer's.
RSpec.describe "edge_stream (what an agent publishes)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }

  def profile(edge_stream: nil)
    Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL", edge_stream: edge_stream)
  end

  def run_turn(prof)
    executor = Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
    chat = FakeChat.new
    chat.final_content = "Temos sim!"
    chat.script = proc do
      emit_thinking("o cliente quer trufas")
      emit_chunk("Temos sim!")
    end
    allow(executor).to receive(:create_chat).and_return(chat)
    session_store.create(id: "s1")
    task = task_store.create(
      command: Insika::Command.build(:send_message, { agent: "sales", message: "oi" }).to_h,
      session_id: "s1", id: "t"
    )
    Sync do
      executor.spawn(task, profile: prof)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  def event_of(type) = event_stream.events.find { |e| e.type == type }

  describe "the default" do
    it "tags neither channel — an internal event stays internal" do
      run_turn(profile)

      expect(event_of(:thinking).data).not_to have_key(:public)
      expect(event_of(:intermediate).data).not_to have_key(:public)
    end

    it "and the edge translates neither" do
      run_turn(profile)

      expect(Insika::Server::Responses.frame_for(event_of(:thinking))).to be_nil
      expect(Insika::Server::Responses.frame_for(event_of(:intermediate))).to be_nil
    end
  end

  describe "an agent that opts thinking in" do
    before { run_turn(profile(edge_stream: { "thinking" => true })) }

    it "tags the reasoning and nothing else" do
      expect(event_of(:thinking).data[:public]).to be(true)
      expect(event_of(:intermediate).data).not_to have_key(:public)
    end

    it "publishes it as REASONING, never as answer text" do
      frame = Insika::Server::Responses.frame_for(event_of(:thinking))

      expect(frame).to include("response.reasoning_summary_text.delta")
      expect(frame).to include("o cliente quer trufas")
      # The one thing that must never happen: a consumer that concatenates
      # output_text deltas into one WhatsApp message would read the deliberation.
      expect(frame).not_to include("output_text")
    end
  end

  describe "an agent that opts the loop narration in" do
    before { run_turn(profile(edge_stream: { "intermediate" => true })) }

    it "publishes it under a NAMESPACED type, because the protocol has no honest one" do
      frame = Insika::Server::Responses.frame_for(event_of(:intermediate))

      # `response.*` would be a lie a strict client believes: in the real protocol
      # this text IS output_text.delta, told apart only by an item index we do not
      # carry. An unknown `insika.*` type is ignored, which is the safe failure.
      expect(frame).to include("insika.intermediate.delta")
      expect(frame).not_to include("response.output_text")
    end

    it "leaves the reasoning channel alone — the switches are independent" do
      expect(Insika::Server::Responses.frame_for(event_of(:thinking))).to be_nil
    end
  end

  describe "the answer" do
    it "is published the same way whatever is opted in — this changes nothing about it" do
      run_turn(profile(edge_stream: { "thinking" => true, "intermediate" => true }))

      expect(Insika::Server::Responses.frame_for(event_of(:content)))
        .to include("response.output_text.delta", "Temos sim!")
    end
  end

  describe "the profile reader" do
    it "tolerates the string values a form or a pack round-trip produces" do
      expect(profile(edge_stream: { "thinking" => "1" }).stream_public?(:thinking)).to be(true)
      expect(profile(edge_stream: { "thinking" => "true" }).stream_public?(:thinking)).to be(true)
    end

    it "reads anything else as off — the safe value is the default one" do
      expect(profile.stream_public?(:thinking)).to be(false)
      expect(profile(edge_stream: {}).stream_public?(:intermediate)).to be(false)
      expect(profile(edge_stream: { "thinking" => "maybe" }).stream_public?(:thinking)).to be(false)
    end
  end
end
