# frozen_string_literal: true

require "spec_helper"
require "async"
require "insika/tools/stuck_signal"

# WS5 stuck signal — the contract the consumer subscribes to: when the agent
# declares it cannot proceed (signal_stuck), the turn ends with a final message
# and the terminal event carries `outcome: :stuck`, plus a dedicated :turn_stuck
# event. The ENGINE carries the state; escalation is the consumer's business.
RSpec.describe "Insika::Executor stuck signal (WS5)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL", stuck_signal: true) }

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

  # The model calls signal_stuck mid-turn: the tool sets state.stuck_outcome and
  # returns a Tool::Halt (ends the loop), which the FakeChat surfaces to ask_on.
  def stuck_chat(lead_in: "Vou te encaminhar para um atendente humano.", reason: "fora do escopo")
    chat = FakeChat.new
    chat.script = proc do
      emit_chunk(lead_in)
      tool = chat.tools.find { |t| t.is_a?(Insika::Tools::StuckSignal) }
      halt = tool.execute(reason: reason)
      chat.halt_with!(halt)
    end
    chat
  end

  before { session_store.create(id: "s1") }

  def run_turn(executor, chat)
    allow(executor).to receive(:create_chat).and_return(chat)
    task = make_task
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  it "completes the turn normally (not a failure)" do
    run_turn(build_executor, stuck_chat)

    expect(event_stream.types).to include(:task_completed)
    expect(event_stream.types).not_to include(:task_failed)
    expect(task_store.find("t").status).to eq(:completed)
  end

  it "the terminal event carries outcome: :stuck and the final message" do
    run_turn(build_executor, stuck_chat)

    data = event_stream.events.find { |e| e.type == :task_completed }.data
    expect(data[:outcome]).to eq(:stuck)
    expect(data[:content]).to eq("Vou te encaminhar para um atendente humano.")
  end

  it "emits a dedicated :turn_stuck event with agent and reason" do
    run_turn(build_executor, stuck_chat)

    ev = event_stream.events.find { |e| e.type == :turn_stuck }
    expect(ev).not_to be_nil
    expect(ev.data).to include(agent: "sales", reason: "fora do escopo")
    expect(ev.data[:message]).to eq("Vou te encaminhar para um atendente humano.")
  end

  it "without a lead-in, publishes the tool's message as the final content" do
    chat = FakeChat.new
    chat.script = proc do
      tool = chat.tools.find { |t| t.is_a?(Insika::Tools::StuckSignal) }
      halt = tool.execute(reason: "sem dados", message: "CALL_SUPPORT")
      chat.halt_with!(halt.content) # the wrapped payload, not the Halt itself
    end

    run_turn(build_executor, chat)

    data = event_stream.events.find { |e| e.type == :task_completed }.data
    expect(data[:outcome]).to eq(:stuck)
    expect(data[:content]).to eq("CALL_SUPPORT")
  end

  it "a normal turn (no signal_stuck) carries no outcome" do
    chat = FakeChat.new
    chat.final_content = "respota normal"

    run_turn(build_executor, chat)

    data = event_stream.events.find { |e| e.type == :task_completed }.data
    expect(data).not_to have_key(:outcome)
    expect(event_stream.types).not_to include(:turn_stuck)
  end
end
