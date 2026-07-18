# frozen_string_literal: true

require "spec_helper"
require "async"
require "tmpdir"
require "fileutils"
require "sqlite3"

# Stage C completion criterion (doc 00 §6) at integration level: a turn
# interrupted by a "crash" survives in a SQLite file, and a "reboot" (new
# objects, SAME file) resumes from the checkpoint via Recovery -> ResumeTask,
# completing without re-executing the non-idempotent tool that already ran.
#
# kill -9 does not run rescue: the post-crash state is assembled DIRECTLY in the
# stores (task :running, open Execution, turn checkpoint, side-effect on the
# standalone key, no live fiber) — simulating via an exception would go through the
# single capture and mark :failed, which is not the scenario. The real-process E2E is task 26.
RSpec.describe "Integration: kill -> restart -> resume" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:db_path) { File.join(@dir, "harness.db") }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }
  # shared side-effect tool: proves it is NOT re-executed on resume.
  let(:tool) do
    Class.new do
      attr_reader :calls

      def initialize = (@calls = 0)
      def name = "send_order"
      def call(_args) = (@calls += 1) && "enviado"
    end.new
  end

  def wiring(store)
    session_store = Harness::SessionStore.new(store: store)
    task_store = Harness::TaskStore.new(store: store)
    checkpoint_store = Harness::CheckpointStore.new(store: store)
    event_stream = Harness::EventStream.new
    executor = Harness::Executor.new(
      context_builder: FakeContextBuilder.new,
      policy_engine: NullPolicyEngine.new(allowed_tools: [tool]),
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new(side_effect_names: ["send_order"]),
      skill_catalog: Harness::SkillCatalog.new([]), profiles: { "sales" => profile },
      session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
    { session_store: session_store, task_store: task_store, checkpoint_store: checkpoint_store,
      event_stream: event_stream, executor: executor }
  end

  it "resumes the interrupted turn, completes and does NOT re-execute the already finished tool" do
    # ── Act 1: the crash (state assembled directly in the file) ─────────────
    store_a = Harness::Stores::SQLite.new(path: db_path)
    a = wiring(store_a)
    a[:session_store].create(id: "s1")
    command = Harness::Command.build(:send_message,
                                     { agent: "sales", message: "faz o pedido", session_id: "s1" })
    a[:task_store].create(command: command.to_h, session_id: "s1", id: "t")
    a[:task_store].begin_execution("t")          # attempt 1 stays OPEN (dead fiber)
    a[:task_store].transition("t", to: :running)
    a[:checkpoint_store].save(Harness::Checkpoint.new(
                                task_id: "t", turn: 1, session_id: "s1", agent_id: "sales",
                                messages: [], completed_side_effects: [], created_at: nil
                              ))
    a[:checkpoint_store].record_side_effect("t", turn: 1, tool_call_id: "call_order")
    store_a.close # "kill"

    # ── Act 2: the reboot (new objects, SAME file) ──────────────────────────
    store_b = Harness::Stores::SQLite.new(path: db_path)
    b = wiring(store_b)
    handler = Harness::Commands::ResumeTask.new(
      profiles: { "sales" => profile }, task_store: b[:task_store],
      checkpoint_store: b[:checkpoint_store], executor: b[:executor]
    )
    bus = Harness::CommandBus.new
    bus.register(:resume_task, handler)

    # model re-requests the SAME tool call (same id) and then responds final.
    fake = FakeChat.new
    fake.final_content = "pedido confirmado"
    fake.script = proc do
      fire_tool_call(name: "send_order", arguments: {}, id: "call_order")
      result = @tools.first.call({})
      fire_tool_result(result)
    end
    allow(b[:executor]).to receive(:create_chat).and_return(fake)

    summary = nil
    events = []
    Sync do |parent|
      sub = b[:event_stream].subscribe
      consumer = parent.async { sub.each { |e| events << e } }
      summary = Harness::Recovery.new(task_store: b[:task_store],
                                      checkpoint_store: b[:checkpoint_store],
                                      command_bus: bus).run
      # the task has a session_id -> the resume is SERIALIZED in the SessionActor (P2-03),
      # spawned async; poll until terminal and stop the session loop.
      100.times do
        t = b[:task_store].find("t")
        break if t && %w[completed failed cancelled].include?(t.status.to_s)

        parent.sleep(0.005)
      end
      b[:executor].stop_session_actors
      sub.close
      consumer.wait
    end
    store_b.close

    # ── Verification (file reopened: real durability) ───────────────────────
    store_c = Harness::Stores::SQLite.new(path: db_path)
    c = wiring(store_c)

    expect(summary[:resumed]).to include("t")
    task = c[:task_store].find("t")
    expect(task.status).to eq(:completed)
    # new Execution: attempt 1 (interrupted) preserved + attempt 2 (complete)
    expect(task.executions.size).to eq(2)
    expect(task.executions.first.outcome).to eq("interrupted")
    expect(task.executions.last.outcome).to eq("completed")
    # the tool was NOT re-executed; the :tool_result carried the marker
    expect(tool.calls).to eq(0)
    result_event = events.find { |e| e.type == :tool_result }
    expect(result_event.data[:result]).to include("already_executed")
    expect(events.map(&:type)).to include(:done, :task_completed)
    # checkpoint advanced (turn 1 -> 2) and prune kept the last one
    expect(c[:checkpoint_store].latest("t").turn).to eq(2)
    # intact session: the turn messages appear ONCE (crash was before step 8)
    expect(c[:session_store].find("s1").messages.map { |m| m["content"] })
      .to eq(["faz o pedido", "pedido confirmado"])

    store_c.close
  end
end
