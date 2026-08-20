# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::EventStream do
  subject(:stream) { described_class.new }

  def evt(type: :content, data: {}, meta: {})
    Insika::Event.new(type: type, data: data, meta: meta)
  end

  # Collects a subscription's events in a consumer fiber until close.
  def collect(parent, sub)
    got = []
    consumer = parent.async { sub.each { |e| got << e } }
    yield
    sub.close
    consumer.wait
    got
  end

  it "fans out to 2 subscriptions without a filter" do
    Sync do |task|
      a = stream.subscribe
      b = stream.subscribe
      got_a = []
      got_b = []
      ca = task.async { a.each { |e| got_a << e } }
      cb = task.async { b.each { |e| got_b << e } }
      stream.emit(evt)
      a.close
      b.close
      ca.wait
      cb.wait
      expect(got_a.size).to eq(1)
      expect(got_b.size).to eq(1)
    end
  end

  it "filters by task_id" do
    Sync do |task|
      sub = stream.subscribe(task_id: "a")
      got = collect(task, sub) do
        stream.emit(evt(meta: { task_id: "a" }))
        stream.emit(evt(meta: { task_id: "b" }))
      end
      expect(got.map { |e| e.meta[:task_id] }).to eq(["a"])
    end
  end

  it "filters by session_id" do
    Sync do |task|
      sub = stream.subscribe(session_id: "s1")
      got = collect(task, sub) do
        stream.emit(evt(meta: { session_id: "s1" }))
        stream.emit(evt(meta: { session_id: "s2" }))
      end
      expect(got.map { |e| e.meta[:session_id] }).to eq(["s1"])
    end
  end

  it "filters by event type (WS6): only the subscribed types enter the queue" do
    Sync do |task|
      sub = stream.subscribe(types: %i[alert_a alert_b])
      got = collect(task, sub) do
        stream.emit(evt(type: :alert_a, meta: { task_id: "t1" }))
        stream.emit(evt(type: :content, meta: { task_id: "t2" })) # full-traffic noise
        stream.emit(evt(type: :alert_b, meta: { task_id: "t3" }))
      end
      expect(got.map(&:type)).to eq(%i[alert_a alert_b])
    end
  end

  it "a typed subscription never accumulates the events it filters out (no overflow)" do
    Sync do |task|
      typed = stream.subscribe(types: %i[alert])
      unfiltered = stream.subscribe # control: a full-traffic subscriber DOES get overflow-closed
      1005.times { stream.emit(evt(type: :content, meta: {})) } # would blow the 1000 cap
      expect(stream.instance_variable_get(:@subscriptions)).to include(typed)
      expect(stream.instance_variable_get(:@subscriptions)).not_to include(unfiltered)

      got = collect(task, typed) { stream.emit(evt(type: :alert, meta: {})) }
      expect(got.map(&:type)).to eq([:alert])
    end
  end

  it "does not deliver an event without task in meta to a subscriber with a task filter; without a filter it receives" do
    Sync do |task|
      filtered = stream.subscribe(task_id: "a")
      unfiltered = stream.subscribe
      got_f = []
      got_u = []
      cf = task.async { filtered.each { |e| got_f << e } }
      cu = task.async { unfiltered.each { |e| got_u << e } }
      stream.emit(evt(type: :session_created, meta: { session_id: "s" })) # no task_id
      filtered.close
      unfiltered.close
      cf.wait
      cu.wait
      expect(got_f).to be_empty
      expect(got_u.size).to eq(1)
    end
  end

  describe "tenant-scoped subscription (WS1)" do
    it "delivers only events whose meta carries the SAME tenant" do
      sub = stream.subscribe(tenant: "loja-a")
      got = Sync { |task| collect(task, sub) do
        stream.emit(evt(meta: { task_id: "t1", tenant: "loja-a" }))
        stream.emit(evt(meta: { task_id: "t2", tenant: "loja-b" }))
      end }
      expect(got.map { |e| e.meta[:task_id] }).to eq(["t1"])
    end

    it "FAIL-CLOSED: an event without a tenant in meta matches NO tenant subscription" do
      sub = stream.subscribe(tenant: "loja-a")
      got = Sync { |task| collect(task, sub) do
        stream.emit(evt(meta: { task_id: "t1" })) # control/operator event, no tenant
      end }
      expect(got).to be_empty
    end

    it "an operator subscription (no tenant filter) still sees everything" do
      sub = stream.subscribe
      got = Sync { |task| collect(task, sub) do
        stream.emit(evt(meta: { task_id: "t1", tenant: "loja-a" }))
        stream.emit(evt(meta: { task_id: "t2" }))
      end }
      expect(got.size).to eq(2)
    end
  end

  it "iterates exactly until close" do
    Sync do |task|
      sub = stream.subscribe
      got = collect(task, sub) { 3.times { |i| stream.emit(evt(data: { n: i })) } }
      expect(got.size).to eq(3)
    end
  end

  it "isolates a broken observer: emit does not raise and the others receive" do
    Sync do |task|
      good = stream.subscribe
      bad = stream.subscribe
      allow(bad).to receive(:push).and_raise("observador quebrado")
      got = []
      c = task.async { good.each { |e| got << e } }
      expect { stream.emit(evt) }.not_to raise_error
      good.close
      c.wait
      expect(got.size).to eq(1)
    end
  end

  it "buffers for a slow consumer: emit does not block (L4)" do
    Sync do |task|
      sub = stream.subscribe
      100.times { stream.emit(evt) } # no active consumer yet
      got = []
      c = task.async { sub.each { |e| got << e } }
      sub.close
      c.wait
      expect(got.size).to eq(100)
    end
  end

  it "does not deliver retroactively: subscribing after emit does not receive the past" do
    Sync do |task|
      stream.emit(evt) # before any subscribe
      sub = stream.subscribe
      got = collect(task, sub) { nil }
      expect(got).to be_empty
    end
  end

  it "emit with no subscribers is a no-op" do
    expect(stream.emit(evt)).to be_nil
  end

  # RFC-0014: the in-process eval transport collects a turn's :tool_call events
  # AFTER the turn returned, without ever blocking (the queue is read-only in a
  # cooperative reactor, so a non-empty dequeue never waits).
  it "drain_nonblocking returns what is already queued and never blocks" do
    sub = stream.subscribe(types: [:tool_call])
    stream.emit(evt(type: :tool_call, data: { name: "search_products" }))
    stream.emit(evt(type: :thinking, data: {})) # filtered out by types
    stream.emit(evt(type: :tool_call, data: { name: "create_order" }))

    drained = sub.drain_nonblocking
    expect(drained.map { |e| e.data[:name] }).to eq(%w[search_products create_order])

    # Already drained -> nothing more, still no block.
    expect(sub.drain_nonblocking).to be_empty
    sub.close
  end

  it "a subscriber is not skipped when another overflows (closes) during the same emit" do
    # A (no filter) saturates up to the cap; B (filtered by task_id) ignores A's
    # traffic. On the critical emit, A overflows -> close -> is removed from the array DURING
    # the each; B matches that same event and MUST NOT be skipped (regression: Array#each
    # + delete used to skip the shifted neighbor).
    Sync do |task|
      a = stream.subscribe                       # no filter: receives everything
      b = stream.subscribe(task_id: "b")          # only events from task "b"
      1000.times { stream.emit(evt(meta: {})) }   # fills A up to the cap; B ignores

      got_b = []
      cb = task.async { b.each { |e| got_b << e } }
      stream.emit(evt(meta: { task_id: "b" }))    # A overflows/leaves; B should receive
      b.close
      cb.wait

      expect(got_b.size).to eq(1) # without the snapshot in emit, it would be 0 (B skipped)
      expect(a).not_to be_nil     # A was closed, but the emit did not raise
    end
  end
end
