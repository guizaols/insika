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
