# frozen_string_literal: true

require "spec_helper"
require "async"

# REAL wiring: CommandBus + SendMessage handler + Executor + domain stores
# over Memory + real EventStream. Scripted chat (FakeChat) via a create_chat
# stub — runs WITHOUT the gem.
RSpec.describe "Integration: SendMessage Command->Response flow" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  let(:executor) do
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "sales" => profile }, session_store: session_store,
      task_store: task_store, checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  let(:bus) { Insika::CommandBus.new }
  let(:handler) do
    Insika::Commands::SendMessage.new(profiles: { "sales" => profile },
                                       session_store: session_store, task_store: task_store,
                                       executor: executor)
  end

  # Scripted FakeChat: 2 chunks + 1 tool call + final response.
  let(:scripted_chat) do
    chat = FakeChat.new
    chat.final_content = "resposta final"
    chat.script = proc do
      emit_chunk("Oi")
      emit_chunk(" tudo bem")
      fire_tool_call(name: "lookup", arguments: { "q" => "x" })
      fire_tool_result("resultado")
    end
    chat
  end

  before do
    bus.register(:send_message, handler)
    allow(executor).to receive(:create_chat).and_return(scripted_chat)
  end

  TERMINAL = %w[completed failed cancelled].freeze

  # A turn with a session_id is SERIALIZED by the SessionActor (03): the turn is
  # spawned ASYNCHRONOUSLY by the session loop, so you cannot wait on
  # @running right after the dispatch. Polls until the terminal state and stops the
  # SessionActors (the loop blocks forever) so the Sync can exit.
  def dispatch_and_wait(payload)
    result = nil
    collected = []
    Sync do |parent|
      sub = event_stream.subscribe
      consumer = parent.async { sub.each { |e| collected << e } }
      result = bus.dispatch(Insika::Command.build(:send_message, payload))
      wait_terminal(parent, result[:task_id])
      executor.stop_session_actors
      sub.close
      consumer.wait
    end
    [result, collected]
  end

  def wait_terminal(parent, task_id)
    100.times do
      t = task_store.find(task_id)
      break if t && TERMINAL.include?(t.status.to_s)

      parent.sleep(0.005)
    end
  end

  it "emits the canonical sequence of events" do
    session_store.create(id: "s1")
    _result, events = dispatch_and_wait(agent: "sales", message: "oi", session_id: "s1")

    # "Oi"/" tudo bem" were said on the message that then called the tool, so
    # they are narration — they ride :intermediate and stop there. Only the message
    # that ENDS the turn ("resposta final") is published as :content, which is the
    # single frame /v1/responses translates.
    expect(events.map(&:type)).to eq(
      %i[task_started intermediate intermediate tool_call tool_result
         intermediate content checkpoint_created task_completed]
    )
  end

  it "monotonic seq and correct meta.task_id/session_id in all" do
    session_store.create(id: "s1")
    result, events = dispatch_and_wait(agent: "sales", message: "oi", session_id: "s1")

    seqs = events.map { |e| e.meta[:seq] }
    expect(seqs).to eq(seqs.sort)
    expect(seqs.uniq.size).to eq(seqs.size) # strictly increasing
    expect(events.map { |e| e.meta[:task_id] }.uniq).to eq([result[:task_id]])
    expect(events.map { |e| e.meta[:session_id] }.uniq).to eq(["s1"])
  end

  it "final state: task :completed, Execution closed, checkpoint turn 2, transcript in the session" do
    session_store.create(id: "s1")
    result, = dispatch_and_wait(agent: "sales", message: "oi", session_id: "s1")

    task = task_store.find(result[:task_id])
    expect(task.status).to eq(:completed)
    expect(task.executions.last.outcome).to eq("completed")
    expect(checkpoint_store.latest(result[:task_id]).turn).to eq(2)
    expect(session_store.find("s1").messages.map { |m| m["content"] }).to eq(["oi", "resposta final"])
  end

  it "responds {task_id:} immediately (before :task_completed)" do
    session_store.create(id: "s1")
    # the response is synchronous even with the turn queued in the SessionActor (03).
    Sync do
      result = bus.dispatch(Insika::Command.build(:send_message,
                                                   { agent: "sales", message: "oi", session_id: "s1" }))
      expect(result).to match({ task_id: kind_of(String) })
    ensure
      executor.stop_session_actors # closes the session loop so the Sync can exit
    end
  end

  it "history-only parity: same flow, session untouched" do
    _result, events = dispatch_and_wait(
      agent: "sales", message: "oi", history: [{ role: "user", content: "anterior" }]
    )

    expect(events.map(&:type)).to include(:task_started, :task_completed)
    expect(session_store.each_id.to_a).to be_empty # no session created/touched
  end
end
