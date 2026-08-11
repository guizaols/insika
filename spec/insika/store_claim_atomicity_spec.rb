# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# a claim must be atomic ACROSS PROCESSES. Two SQLite handles
# on the same file — the honest stand-in for two Falcon workers — race the same
# claim; exactly one may win. In-process serialization (the store's semaphore)
# proves nothing here: each handle has its own; only SQLite's file locking can
# make the property hold.
#
# The get->set window in a claim is microseconds wide, far too narrow for a
# timing race to hit reliably (200 barrier-started thread rounds: 0 collisions).
# So the race is made deterministic instead: each racing handle is wrapped in a
# store decorator whose #get waits for the OTHER handle's #get before returning.
#   - Without a transaction around the claim, both handles read the claimable
#     status before either writes — both win, the spec is red.
#   - With the claim inside `Store#transaction` (BEGIN IMMEDIATE), the loser
#     blocks at the lock and never reaches its read; the rendezvous times out,
#     the winner proceeds alone, and the loser then reads the claimed status.
# The timeout only weakens the magnification — it can never fake a pass.
RSpec.describe "claim atomicity across SQLite handles" do
  # Two-party latch: each arrival waits (up to timeout) for the other.
  class ClaimRendezvous
    def initialize(timeout: 0.2)
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @remaining = 2
      @timeout = timeout
    end

    def arrive_and_wait
      @mutex.synchronize do
        @remaining -= 1
        @remaining <= 0 ? @cond.broadcast : @cond.wait(@mutex, @timeout)
      end
    end
  end

  # Delegates to a real store; #get additionally holds at the rendezvous so
  # both racers finish reading before either writes (when nothing stops them).
  class RendezvousStore
    include Insika::Store

    def initialize(inner, rendezvous)
      @inner = inner
      @rendezvous = rendezvous
    end

    def get(scope, key)
      value = @inner.get(scope, key)
      @rendezvous.arrive_and_wait
      value
    end

    def set(scope, key, value) = @inner.set(scope, key, value)
    def delete(scope, key) = @inner.delete(scope, key)
    def list(scope, prefix = nil) = @inner.list(scope, prefix)
    def transaction(&) = @inner.transaction(&)
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:db_path) { File.join(tmpdir, "claims.db") }
  let(:handle_a) { Insika::Stores::SQLite.new(path: db_path) }
  let(:handle_b) { Insika::Stores::SQLite.new(path: db_path) }
  let(:rendezvous) { ClaimRendezvous.new }

  after do
    handle_a.close
    handle_b.close
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  # Runs both claims concurrently from a common start line; returns [a, b].
  def race(claim_a, claim_b)
    barrier = Queue.new
    results = Array.new(2)
    threads = [claim_a, claim_b].each_with_index.map do |claim, i|
      Thread.new do
        barrier.pop
        results[i] = claim.call
      end
    end
    2.times { barrier << :go }
    threads.each(&:join)
    results
  end

  it "OutboxStore#claim: exactly one handle wins pending -> delivering" do
    Insika::OutboxStore.new(store: handle_a).create(
      channel: "relay", to: "user", task_id: "t", session_id: "s",
      payload: { "text" => "hi" }, id: "d-1"
    )
    racer_a = Insika::OutboxStore.new(store: RendezvousStore.new(handle_a, rendezvous))
    racer_b = Insika::OutboxStore.new(store: RendezvousStore.new(handle_b, rendezvous))

    results = race(-> { racer_a.claim("d-1") }, -> { racer_b.claim("d-1") })

    expect(results.count(true)).to eq(1), "both handles claimed d-1: #{results.inspect}"
  end

  it "DelegationStore#claim_delivery: exactly one handle wins completed -> delivered" do
    setup = Insika::DelegationStore.new(store: handle_a)
    delegation = setup.create(
      parent_task_id: "pt", parent_session_id: "ps", parent_agent: "parent",
      child_agent: "researcher", child_task_id: "ct", child_session_id: "cs", depth: 1
    )
    setup.mark_completed(delegation.id, result: "x")
    racer_a = Insika::DelegationStore.new(store: RendezvousStore.new(handle_a, rendezvous))
    racer_b = Insika::DelegationStore.new(store: RendezvousStore.new(handle_b, rendezvous))

    results = race(-> { racer_a.claim_delivery(delegation.id) },
                   -> { racer_b.claim_delivery(delegation.id) })

    expect(results.count(true)).to eq(1), "both handles claimed #{delegation.id}: #{results.inspect}"
  end

  it "TaskStore#transition: exactly one handle dispatches queued -> running" do
    task = Insika::TaskStore.new(store: handle_a)
                            .create(command: { "type" => "send_message" }, id: "task-1")
    racer_a = Insika::TaskStore.new(store: RendezvousStore.new(handle_a, rendezvous))
    racer_b = Insika::TaskStore.new(store: RendezvousStore.new(handle_b, rendezvous))
    dispatch = lambda do |task_store|
      task_store.transition(task.id, to: :running)
      :won
    rescue ArgumentError # the loser sees running -> running, the loud logical race
      :lost
    end

    results = race(-> { dispatch.call(racer_a) }, -> { dispatch.call(racer_b) })

    expect(results.count(:won)).to eq(1), "both handles dispatched task-1: #{results.inspect}"
  end
end
