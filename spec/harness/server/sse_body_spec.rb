# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../server/sse_body"

RSpec.describe Harness::Server::SSEBody do
  # Spy subscription: delivers events and records close/cancel. `cancel` must
  # NEVER be called (L4: the SSEBody never cancels the task).
  class SpySub
    attr_reader :closed, :cancelled

    def initialize(events = [])
      @events = events
      @closed = false
      @cancelled = false
    end

    def each
      @events.each { |e| yield e }
    end

    def close = (@closed = true)
    def cancel = (@cancelled = true)
  end

  def ev(type, data = {}, meta = { task_id: "t" })
    Harness::Event.new(type: type, data: data, meta: meta)
  end

  # SSEBody is a Rack 3 STREAMING body: driven by `#call(stream)`, where
  # `stream` responds to #write/#close (the SSEStreamDouble collects the frames). This
  # mirrors the Protocol::HTTP::Body::Stream that protocol-rack passes in production.
  it "formats the wire as Event#to_h in JSON (D5)" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    event = ev(:content, { delta: "x" })
    fs = SSEStreamDouble.new

    Sync do
      collector = Async { described_class.new(subscription: sub).call(fs) }
      stream.emit(event)
      sub.close
      collector.wait
    end

    expect(fs.chunks.first).to eq("data: #{JSON.generate(event.to_h)}\n\n")
  end

  it "honors the injected serialize: and skips events it maps to nil" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    fs = SSEStreamDouble.new
    # custom serializer: only :content becomes a frame; the rest is skipped (nil).
    serialize = ->(e) { e.type == :content ? "X:#{e.data[:delta]}\n\n" : nil }

    Sync do
      collector = Async { described_class.new(subscription: sub, serialize: serialize).call(fs) }
      stream.emit(ev(:content, { delta: "a" }))
      stream.emit(ev(:task_started))            # -> nil, skipped
      stream.emit(ev(:content, { delta: "b" }))
      sub.close
      collector.wait
    end

    expect(fs.chunks).to eq(["X:a\n\n", "X:b\n\n"])
  end

  it "preserves the event order" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    events = (1..3).map { |i| ev(:content, { delta: i.to_s }, { task_id: "t", seq: i }) }
    fs = SSEStreamDouble.new

    Sync do
      collector = Async { described_class.new(subscription: sub).call(fs) }
      events.each { |e| stream.emit(e) }
      sub.close
      collector.wait
    end

    expect(fs.chunks).to eq(events.map { |e| "data: #{JSON.generate(e.to_h)}\n\n" })
  end

  it "emits a heartbeat after silence longer than the interval" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    fs = SSEStreamDouble.new

    Sync do |task|
      collector = Async { described_class.new(subscription: sub, heartbeat: 0.05).call(fs) }
      task.sleep(0.15) # no events: forces ≥1 heartbeat timeout
      sub.close
      collector.wait
    end

    expect(fs.chunks).to include(": ping\n\n")
  end

  it "ends #call when the subscription is closed by the caller" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    finished = false

    Sync do
      collector = Async do
        described_class.new(subscription: sub).call(SSEStreamDouble.new)
        finished = true
      end
      sub.close
      collector.wait
    end

    expect(finished).to be(true)
  end

  it "client disconnects: closes the subscription, does not propagate an exception, does not cancel the task" do
    sub = SpySub.new([ev(:content, { delta: "x" })])
    fs = SSEStreamDouble.new(raise_on_write: true) # stream.write raises = closed socket

    Sync do
      expect do
        described_class.new(subscription: sub).call(fs)
      end.not_to raise_error
    end

    expect(sub.closed).to be(true)
    expect(sub.cancelled).to be(false) # L4: execution belongs to the runtime
    expect(fs.closed?).to be(true)     # the body always closes the stream
  end

  describe "cap of 1000 events per Subscription (doc 07 §5)" do
    it "closes with a local :error when exceeding the cap; emit never blocks" do
      stream = Harness::EventStream.new
      sub = stream.subscribe

      # 1001 emissions without consumption: the 1001st overflows the cap. `emit` is O(subscribers)
      # and never blocks — if it blocked, this loop would hang.
      1001.times { |i| stream.emit(Harness::Event.new(type: :content, data: { i: i }, meta: {})) }

      collected = []
      Sync { sub.each { |e| collected << e } }

      expect(collected.last.type).to eq(:error)
      expect(collected.last.to_h[:message]).to eq("subscription overflow")
    end
  end
end
