# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/queue"

RSpec.describe Insika::SessionActor do
  # Fake executor: run_serial records start/done and BLOCKS on a release token
  # (simulates the turn taking time), allowing us to observe serialization.
  class FakeExec
    attr_reader :events, :release

    def initialize(raise_on: nil)
      @events = []
      @release = Async::Queue.new
      @raise_on = raise_on
    end

    def run_serial(task, profile:, resume_from: nil)
      @events << [:start, task.id]
      @release.dequeue
      raise "boom" if task.id == @raise_on

      @events << [:done, task.id]
    end
  end

  def task(id) = Struct.new(:id, :session_id).new(id, "s")

  # RFC-0015 §5.3: the actor writes merges through the executor's task_store and
  # announces a closed window through #emit_coalesced.
  class CollectExec < FakeExec
    attr_reader :task_store, :coalesced

    def initialize(**kwargs)
      super
      @task_store = FakeTaskStore.new
      @coalesced = []
    end

    def emit_coalesced(task, merged:) = @coalesced << [task.id, merged]
  end

  class FakeTaskStore
    attr_reader :messages

    def initialize
      @messages = Hash.new { |h, k| h[k] = [] }
      @released = []
    end

    # Mirrors the real guard: appending to a task that already left :queued raises.
    def append_message(id, text)
      raise ArgumentError, "task #{id} is running, not queued" if @released.include?(id)

      @messages[id] << text
    end

    def release!(id) = @released << id
    def find(id) = Struct.new(:id, :session_id).new(id, "s")
  end

  def policy(debounce_ms:, mode: :collect, max: 10_000)
    Insika::QueuePolicy.new(mode: mode, debounce_ms: debounce_ms, debounce_max_ms: max)
  end

  it "serializes: the 2nd turn only runs after the 1st completes (FIFO)" do
    Sync do |top|
      exec = FakeExec.new
      sa = described_class.new(session_id: "s", executor: exec, parent: top)
      sa.enqueue(task("t1"), profile: nil)
      sa.enqueue(task("t2"), profile: nil)
      top.sleep(0.02)

      expect(exec.events).to eq([[:start, "t1"]]) # only t1 started
      expect(sa.running?).to be(true)
      expect(sa.depth).to eq(1)                   # t2 waits in the queue

      exec.release.enqueue(:go)                   # completes t1
      top.sleep(0.02)
      expect(exec.events).to eq([[:start, "t1"], [:done, "t1"], [:start, "t2"]])

      exec.release.enqueue(:go)                   # completes t2
      top.sleep(0.02)
      expect(exec.events.last).to eq([:done, "t2"])
      sa.stop
    end
  end

  it "a turn that fails does NOT bring down the loop (the next one runs)" do
    Sync do |top|
      exec = FakeExec.new(raise_on: "t1")
      sa = described_class.new(session_id: "s", executor: exec, parent: top)
      sa.enqueue(task("t1"), profile: nil)
      sa.enqueue(task("t2"), profile: nil)
      top.sleep(0.02)
      exec.release.enqueue(:go) # t1 raises inside run_serial
      top.sleep(0.02)
      exec.release.enqueue(:go) # t2 proceeds normally
      top.sleep(0.02)
      expect(exec.events).to include([:start, "t2"], [:done, "t2"])
      sa.stop
    end
  end

  describe "RFC-0015 collect + debounce" do
    it "holds the turn at the door and merges the fragments that arrive in the window" do
      Sync do |top|
        exec = CollectExec.new
        sa = described_class.new(session_id: "s", executor: exec, parent: top)
        sa.enqueue(task("t1"), profile: nil, policy: policy(debounce_ms: 40))

        top.sleep(0.01)
        expect(exec.events).to be_empty      # still at the door, NOT running
        expect(sa.collecting?).to be(true)

        expect(sa.collect("queria o pedido")).to eq("t1")
        top.sleep(0.02)
        expect(sa.collect("1234567")).to eq("t1")
        expect(exec.events).to be_empty      # each fragment restarted the window

        top.sleep(0.09)                      # a full slice of silence elapses
        expect(exec.events).to eq([[:start, "t1"]])
        expect(exec.task_store.messages["t1"]).to eq(["queria o pedido", "1234567"])
        expect(exec.coalesced).to eq([["t1", 3]])
        exec.release.enqueue(:go)
        sa.stop
      end
    end

    it "closes the window once the turn is released: a later fragment does not merge" do
      Sync do |top|
        exec = CollectExec.new
        sa = described_class.new(session_id: "s", executor: exec, parent: top)
        sa.enqueue(task("t1"), profile: nil, policy: policy(debounce_ms: 20))

        top.sleep(0.06) # window closes, the turn starts and blocks in run_serial
        expect(exec.events).to eq([[:start, "t1"]])
        expect(sa.collecting?).to be(false)
        expect(sa.collect("tarde demais")).to be_nil
        exec.release.enqueue(:go)
        sa.stop
      end
    end

    it "a lost race (the task left :queued) reads as 'no merge', not as an error" do
      Sync do |top|
        exec = CollectExec.new
        sa = described_class.new(session_id: "s", executor: exec, parent: top)
        sa.enqueue(task("t1"), profile: nil, policy: policy(debounce_ms: 40))
        top.sleep(0.01)

        exec.task_store.release!("t1") # the store now refuses the append
        expect(sa.collect("fragmento")).to be_nil
        exec.release.enqueue(:go)
        sa.stop
      end
    end

    it "debounce_max_ms stops a customer who keeps typing from deferring forever" do
      Sync do |top|
        exec = CollectExec.new
        sa = described_class.new(session_id: "s", executor: exec, parent: top)
        sa.enqueue(task("t1"), profile: nil, policy: policy(debounce_ms: 20, max: 50))

        # A fragment every slice would restart the window indefinitely without the cap.
        6.times do
          top.sleep(0.021)
          sa.collect("mais um")
        end

        expect(exec.events).to eq([[:start, "t1"]]) # the ceiling released it anyway
        exec.release.enqueue(:go)
        sa.stop
      end
    end

    it "no policy (and a policy without a window) keeps today's path: no door, no merging" do
      Sync do |top|
        exec = CollectExec.new
        sa = described_class.new(session_id: "s", executor: exec, parent: top)
        sa.enqueue(task("t1"), profile: nil)
        sa.enqueue(task("t2"), profile: nil, policy: policy(debounce_ms: 0))

        top.sleep(0.02)
        expect(exec.events).to eq([[:start, "t1"]])
        expect(sa.collecting?).to be(false)
        expect(sa.collect("nada pra mesclar")).to be_nil
        expect(exec.coalesced).to be_empty
        2.times { exec.release.enqueue(:go) }
        sa.stop
      end
    end

    it "a window that merged nothing emits no :turn_coalesced and does not re-read the task" do
      Sync do |top|
        exec = CollectExec.new
        sa = described_class.new(session_id: "s", executor: exec, parent: top)
        sa.enqueue(task("t1"), profile: nil, policy: policy(debounce_ms: 20))

        top.sleep(0.06)
        expect(exec.events).to eq([[:start, "t1"]])
        expect(exec.coalesced).to be_empty
        exec.release.enqueue(:go)
        sa.stop
      end
    end
  end

  it "depth reflects the queue; running? false when idle" do
    Sync do |top|
      exec = FakeExec.new
      sa = described_class.new(session_id: "s", executor: exec, parent: top)
      sa.enqueue(task("t1"), profile: nil)
      sa.enqueue(task("t2"), profile: nil)
      sa.enqueue(task("t3"), profile: nil)
      top.sleep(0.02)
      expect(sa.depth).to eq(2) # t1 running, t2/t3 in the queue
      3.times { exec.release.enqueue(:go) }
      top.sleep(0.03)
      expect(sa.running?).to be(false)
      expect(sa.depth).to eq(0)
      sa.stop
    end
  end
end
