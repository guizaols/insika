# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/queue"
require "tmpdir"

# the periodic tick. Properties under test: the outbox drain runs
# for every worker on every pass (per-record claims make that safe); the
# recovery half runs for exactly ONE worker per window (the single-key claim);
# a failing pass is logged and the loop keeps ticking; interval 0 disables.
RSpec.describe Insika::Tick do
  let(:backend) { Insika::Stores::Memory.new }

  # Doubles — the real collaborators have their own suites (channel_delivery,
  # recovery); here only the orchestration matters.
  class FakeChannelDelivery
    attr_reader :sweeps

    def initialize(raise_on_first: false)
      @sweeps = 0
      @raise_on_first = raise_on_first
    end

    def sweep
      @sweeps += 1
      raise Insika::StoreError, "store piscou" if @raise_on_first && @sweeps == 1

      { dispatched: ["d#{@sweeps}"] }
    end
  end

  class FakeRecovery
    attr_reader :calls

    def initialize
      @calls = []
    end

    def run(stale_after: nil)
      @calls << stale_after
      { resumed: ["t#{@calls.size}"], failed: [] }
    end
  end

  let(:delivery) { FakeChannelDelivery.new }
  let(:recovery) { FakeRecovery.new }

  subject(:tick) do
    described_class.new(store: backend, recovery: recovery, channel_delivery: delivery,
                        interval: 60, stale_after: 900)
  end

  # Ages the single claim key so the next pass sees an expired window.
  def expire_claim(store = backend)
    store.set("tick", "claim", { "claimed_at" => (Time.now.utc - 120).iso8601 })
  end

  describe "#run_once" do
    it "drains the outbox AND sweeps with the configured threshold, in one summary" do
      result = tick.run_once

      expect(delivery.sweeps).to eq(1)
      expect(recovery.calls).to eq([900])
      expect(result).to eq({ dispatched: ["d1"], resumed: ["t1"], failed: [] })
    end

    # the outcome fold rides the tick next to retention — the
    # summary carries its claim result, and a nil fold changes nothing.
    it "calls the funnel fold every pass and reports it in the summary" do
      fold = instance_double(Insika::FunnelFold, run: { claimed: true, folded: 2, skipped: 0, pairs: 1 })
      tick.funnel = fold

      result = tick.run_once

      expect(fold).to have_received(:run)
      expect(result[:funnel]).to eq(claimed: true, folded: 2, skipped: 0, pairs: 1)
    end

    it "a nil funnel (base wiring) leaves the summary byte-identical" do
      expect(tick.run_once).not_to have_key(:funnel)
    end

    it "one sweeper per window: a second worker drains but does NOT sweep" do
      other_recovery = FakeRecovery.new
      other = described_class.new(store: backend, recovery: other_recovery,
                                  channel_delivery: FakeChannelDelivery.new,
                                  interval: 60, stale_after: 900)

      tick.run_once
      other.run_once

      expect(recovery.calls.size).to eq(1)
      expect(other_recovery.calls).to be_empty
      expect(other.run_once).to include(dispatched: be_an(Array)) # drain is ungated
    end

    it "sweeps again once the window expires" do
      tick.run_once
      expire_claim

      tick.run_once

      expect(recovery.calls.size).to eq(2)
    end

    it "a corrupted claim record is not a claim — takes the window" do
      backend.set("tick", "claim", { "claimed_at" => "lixo" })

      tick.run_once

      expect(recovery.calls.size).to eq(1)
    end

    it "a StoreError from the claim propagates (the loop is the rescue boundary)" do
      exploding = Class.new do
        def transaction(*) = raise Insika::StoreError, "backend morreu"
      end.new
      tick = described_class.new(store: exploding, recovery: recovery,
                                 channel_delivery: delivery, interval: 60)

      expect { tick.run_once }.to raise_error(Insika::StoreError)
    end

    # the single-key window claim across real concurrent handles —
    # the same property proved for the boot claim.
    it "exactly one of two SQLite handles sweeps the same window (cross-process claim)" do
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, "tick.db")
        handle_a = Insika::Stores::SQLite.new(path: db_path)
        handle_b = Insika::Stores::SQLite.new(path: db_path)
        recoveries = [FakeRecovery.new, FakeRecovery.new]
        barrier = Queue.new
        threads = [handle_a, handle_b].each_with_index.map do |handle, i|
          Thread.new do
            barrier.pop
            described_class.new(store: handle, recovery: recoveries[i],
                                channel_delivery: FakeChannelDelivery.new, interval: 60).run_once
          end
        end
        2.times { barrier << :go }
        threads.each(&:join)

        expect(recoveries.sum { |r| r.calls.size }).to eq(1),
          "both workers swept the same window: #{recoveries.map { |r| r.calls.size }.inspect}"
      ensure
        handle_a&.close
        handle_b&.close
      end
    end
  end

  describe "#enabled?" do
    it "is false at interval 0 (the off switch)" do
      off = described_class.new(store: backend, recovery: recovery,
                                channel_delivery: delivery, interval: 0)

      expect(off.enabled?).to be(false)
      expect(off.start(parent: nil)).to be(false)
    end
  end

  describe "#start (the loop on the supervisor fiber)" do
    let(:passes) { Async::Queue.new }
    let(:logger) do
      Class.new do
        attr_reader :warned

        def initialize = (@warned = [])

        def warn(message) = @warned << message
      end.new
    end

    # A pass must YIELD, or the loop fiber starves the reactor (and the test's
    # own coordinator) — the real sleeper (task.sleep) yields by construction.
    def yielding_sleeper
      ->(_seconds) { passes << :pass; Async::Task.current.sleep(0.001) }
    end

    it "ticks repeatedly as a child of the parent, and stops with it" do
      delivery = FakeChannelDelivery.new
      looper = described_class.new(store: backend, recovery: FakeRecovery.new,
                                   channel_delivery: delivery, interval: 60,
                                   sleeper: yielding_sleeper)

      Sync do |top|
        parent = top.async { Async::Queue.new.dequeue }
        expect(looper.start(parent: parent)).to be(true)
        waiter = top.async do
          3.times { passes.dequeue } # push N happens before sweep N; 3 pushes == 2 sweeps done
          parent.stop
        end
        waiter.wait
      end

      expect(delivery.sweeps).to be >= 2
    end

    it "a failing pass logs and the loop keeps ticking" do
      delivery = FakeChannelDelivery.new(raise_on_first: true)
      looper = described_class.new(store: backend, recovery: FakeRecovery.new,
                                   channel_delivery: delivery, interval: 60,
                                   logger: logger, sleeper: yielding_sleeper)

      Sync do |top|
        parent = top.async { Async::Queue.new.dequeue }
        looper.start(parent: parent)
        waiter = top.async do
          3.times { passes.dequeue } # push N happens before sweep N; 3 pushes == 2 sweeps done
          parent.stop
        end
        waiter.wait
      end

      expect(delivery.sweeps).to be >= 2
      expect(logger.warned.join).to match(/tick failed: Insika::StoreError/)
    end

    it "is idempotent while running (one loop per supervisor)" do
      looper = described_class.new(store: backend, recovery: FakeRecovery.new,
                                   channel_delivery: FakeChannelDelivery.new,
                                   interval: 60, sleeper: yielding_sleeper)

      Sync do |top|
        parent = top.async { Async::Queue.new.dequeue }
        looper.start(parent: parent)
        expect(looper.start(parent: parent)).to be(true) # already running
        waiter = top.async do
          passes.dequeue
          expect(parent.children.each.count(&:running?)).to eq(1) # just the one loop
          parent.stop
        end
        waiter.wait
      end
    end
  end

  describe "integration with the real Recovery (the hole, closed)" do
    let(:task_store) { Insika::TaskStore.new(store: backend) }
    let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
    let(:bus) do
      Class.new do
        attr_reader :dispatched

        def initialize = (@dispatched = [])

        def dispatch(command) = @dispatched << command
      end.new
    end

    it "a stale orphan left by a dead worker is resumed by the tick, no reboot" do
      task_store.create(command: { "type" => "send_message", "payload" => {} }, id: "orphan")
      task_store.begin_execution("orphan")
      task_store.transition("orphan", to: :running)
      checkpoint_store.save(Insika::Checkpoint.new(task_id: "orphan", turn: 1, session_id: "s",
                                                   agent_id: "a", messages: [],
                                                   completed_side_effects: [], created_at: nil))
      key = "task:orphan"
      record = backend.get("tasks", key)
      record["updated_at"] = (Time.now.utc - 1_000).iso8601
      backend.set("tasks", key, record)

      real = Insika::Recovery.new(task_store: task_store, checkpoint_store: checkpoint_store,
                                  command_bus: bus)
      tick = described_class.new(store: backend, recovery: real,
                                 channel_delivery: FakeChannelDelivery.new,
                                 interval: 60, stale_after: 900)

      result = tick.run_once

      expect(result[:resumed]).to eq(["orphan"])
      expect(bus.dispatched.map(&:type)).to eq([:resume_task])
    end
  end

  describe "the follow-up firer (— the tick's third duty)" do
    let(:firer) { double("followup engine", run: { claimed: true, fired: 1, blocked: 0, errors: 0, blocked_reasons: {}, deferred: 0 }) }

    it "calls the firer each pass and carries its summary under :followup" do
      tick = described_class.new(store: backend, recovery: recovery, channel_delivery: delivery,
                                 interval: 60, stale_after: 900, followup: firer)
      result = tick.run_once
      expect(firer).to have_received(:run).once
      expect(result[:followup]).to eq(fired: 1, blocked: 0, errors: 0, blocked_reasons: {}, deferred: 0, claimed: true)
    end

    it "nil followup = no key in the summary (parity)" do
      tick = described_class.new(store: backend, recovery: recovery, channel_delivery: delivery,
                                 interval: 60, stale_after: 900)
      expect(tick.run_once).not_to have_key(:followup)
    end

    it "exposes the setter (the graph wires the engine after the tick is built)" do
      tick = described_class.new(store: backend, recovery: recovery,
                                 channel_delivery: delivery, interval: 60, stale_after: 900)
      tick.followup = firer
      expect(tick.followup).to be(firer)
    end
  end

  describe "the schedule firer (the tick's fourth duty)" do
    let(:firer) do
      double("schedule engine",
             run: { claimed: true, fired: 1, skipped: 0, errors: 0, skip_reasons: {} })
    end

    it "calls the firer each pass and carries its summary under :schedule" do
      tick = described_class.new(store: backend, recovery: recovery,
                                 channel_delivery: delivery, interval: 60,
                                 stale_after: 900, schedule: firer)
      result = tick.run_once
      expect(firer).to have_received(:run).once
      expect(result[:schedule]).to eq(fired: 1, skipped: 0, errors: 0, skip_reasons: {},
                                      claimed: true)
    end

    it "nil schedule = no key in the summary (parity)" do
      tick = described_class.new(store: backend, recovery: recovery,
                                 channel_delivery: delivery, interval: 60, stale_after: 900)
      expect(tick.run_once).not_to have_key(:schedule)
    end

    it "exposes the setter (the graph wires the engine after the tick is built)" do
      tick = described_class.new(store: backend, recovery: recovery,
                                 channel_delivery: delivery, interval: 60, stale_after: 900)
      tick.schedule = firer
      expect(tick.schedule).to be(firer)
    end
  end
end
