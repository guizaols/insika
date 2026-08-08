# frozen_string_literal: true

require "spec_helper"
require "async"
require "tmpdir"
require "fileutils"
require "sqlite3"

# E2 (RFC-0016 §6): recovery under multi-worker. Two "workers" — two full
# stacks over two SQLite handles on the SAME file, the honest stand-in for two
# Falcon workers — boot after a kill -9, both reach for the sweep, and the turn
# interrupted mid-flight must be resumed EXACTLY ONCE, with the already-executed
# side-effect skipped (RFC-0006's property is what is under test).
#
# The mechanism is the per-generation sweep claim, not a per-task claim: the
# sweep's "orphaned :running" test cannot see another process's live fiber, so
# without the pin the second worker re-runs the first worker's resume (double
# provider call, doubled session messages, a third Execution). Verified red:
# with both sweeps ungated this spec fails exactly that way.
RSpec.describe "Integration: two workers boot, one sweeps (RFC-0016 E2)" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:db_path) { File.join(@dir, "insika.db") }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }
  # ONE shared side-effect counter across both workers: proves the tool ran on
  # neither (the checkpoint says it already executed before the crash).
  let(:tool) do
    Class.new do
      attr_reader :calls

      def initialize = (@calls = 0)
      def name = "send_order"
      def call(_args) = (@calls += 1) && "enviado"
    end.new
  end

  def worker(store)
    session_store = Insika::SessionStore.new(store: store)
    task_store = Insika::TaskStore.new(store: store)
    checkpoint_store = Insika::CheckpointStore.new(store: store)
    executor = Insika::Executor.new(
      context_builder: FakeContextBuilder.new,
      policy_engine: NullPolicyEngine.new(allowed_tools: [tool]),
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new(side_effect_names: ["send_order"]),
      skill_catalog: Insika::SkillCatalog.new([]), profiles: { "sales" => profile },
      session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: Insika::EventStream.new
    )
    bus = Insika::CommandBus.new
    bus.register(:resume_task, Insika::Commands::ResumeTask.new(
                                 profiles: { "sales" => profile }, task_store: task_store,
                                 checkpoint_store: checkpoint_store, executor: executor
                               ))
    { store: store, task_store: task_store, checkpoint_store: checkpoint_store,
      session_store: session_store, executor: executor, bus: bus }
  end

  # The model of the resumed turn: re-requests the SAME tool call (same id,
  # skipped via the checkpoint marker) and answers final.
  def stub_chat(worker)
    fake = FakeChat.new
    fake.final_content = "pedido confirmado"
    fake.script = proc do
      fire_tool_call(name: "send_order", arguments: {}, id: "call_order")
      result = @tools.first.call({})
      fire_tool_result(result)
    end
    allow(worker[:executor]).to receive(:create_chat).and_return(fake)
    fake
  end

  # What each worker's boot does (Server::Boot#do_recovery, task-sweep half):
  # claim the generation, sweep only if it won. -> the recovery summary or nil.
  def boot_sweep(worker, boot_id:)
    return nil unless Insika::Recovery.claim_sweep(store: worker[:store], boot_id: boot_id)

    summary = Insika::Recovery.new(
      task_store: worker[:task_store], checkpoint_store: worker[:checkpoint_store],
      command_bus: worker[:bus]
    ).run
    100.times do
      task = worker[:task_store].find("t")
      break if task && %w[completed failed cancelled].include?(task.status.to_s)

      sleep(0.005) # scheduler-aware under the Sync reactor
    end
    worker[:executor].stop_session_actors
    summary
  end

  it "the turn is resumed exactly once, side-effect skipped, by whichever worker claims" do
    # ── Act 1: the crash (kill -9 leaves the state, no rescue ran) ──────────
    store_crash = Insika::Stores::SQLite.new(path: db_path)
    crash = worker(store_crash)
    crash[:session_store].create(id: "s1")
    command = Insika::Command.build(:send_message,
                                    { agent: "sales", message: "faz o pedido", session_id: "s1" })
    crash[:task_store].create(command: command.to_h, session_id: "s1", id: "t")
    crash[:task_store].begin_execution("t") # attempt 1 stays OPEN (dead fiber)
    crash[:task_store].transition("t", to: :running)
    crash[:checkpoint_store].save(Insika::Checkpoint.new(
                                    task_id: "t", turn: 1, session_id: "s1", agent_id: "sales",
                                    messages: [], completed_side_effects: [], created_at: nil
                                  ))
    crash[:checkpoint_store].record_side_effect("t", turn: 1, tool_call_id: "call_order")
    store_crash.close # "kill -9"

    # ── Act 2: TWO workers reboot on the same file, same boot generation ────
    store_a = Insika::Stores::SQLite.new(path: db_path)
    store_b = Insika::Stores::SQLite.new(path: db_path)
    worker_a = worker(store_a)
    worker_b = worker(store_b)
    stub_chat(worker_a)
    stub_chat(worker_b)

    barrier = Queue.new
    summaries = Array.new(2)
    threads = [worker_a, worker_b].each_with_index.map do |w, i|
      Thread.new do
        barrier.pop
        Sync { summaries[i] = boot_sweep(w, boot_id: "deploy-1") }
      end
    end
    2.times { barrier << :go }
    threads.each(&:join)
    store_a.close
    store_b.close

    # ── Verification (file reopened: what production would see) ─────────────
    store_check = Insika::Stores::SQLite.new(path: db_path)
    check = worker(store_check)

    swept = summaries.compact
    expect(swept.size).to eq(1), "both workers swept: #{summaries.inspect}"
    expect(swept.first[:resumed]).to eq(["t"])

    task = check[:task_store].find("t")
    expect(task.status).to eq(:completed)
    # attempt 1 (interrupted) + attempt 2 (completed) — a third attempt is the
    # double-resume this spec exists to forbid.
    expect(task.executions.size).to eq(2)
    expect(task.executions.first.outcome).to eq("interrupted")
    expect(task.executions.last.outcome).to eq("completed")
    # the side-effect did not run again on either worker
    expect(tool.calls).to eq(0)
    # the turn's messages landed ONCE
    expect(check[:session_store].find("s1").messages.map { |m| m["content"] })
      .to eq(["faz o pedido", "pedido confirmado"])

    store_check.close
  end

  it "a worker respawned mid-generation does not steal the generation's turns" do
    # The generation was already claimed (the original boot); a respawned worker
    # re-runs the same boot path and must skip the sweep even though it sees a
    # :running task with no fiber of its own.
    store_a = Insika::Stores::SQLite.new(path: db_path)
    original = worker(store_a)
    expect(Insika::Recovery.claim_sweep(store: store_a, boot_id: "deploy-9")).to be(true)
    original[:session_store].create(id: "s1")
    command = Insika::Command.build(:send_message,
                                    { agent: "sales", message: "oi", session_id: "s1" })
    original[:task_store].create(command: command.to_h, session_id: "s1", id: "live")
    original[:task_store].begin_execution("live")
    original[:task_store].transition("live", to: :running) # a LIVE turn in this worker

    store_respawn = Insika::Stores::SQLite.new(path: db_path)
    respawned = worker(store_respawn)

    summary = Sync { boot_sweep(respawned, boot_id: "deploy-9") }

    expect(summary).to be_nil # claim lost -> no sweep
    expect(original[:task_store].find("live").status).to eq(:running) # untouched
    expect(original[:task_store].find("live").executions.size).to eq(1)

    store_a.close
    store_respawn.close
  end
end
