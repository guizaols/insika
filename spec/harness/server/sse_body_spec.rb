# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../server/sse_body"

RSpec.describe Harness::Server::SSEBody do
  # Subscription-espião: entrega eventos e grava close/cancel. `cancel` NUNCA
  # deve ser chamado (L4: a SSEBody jamais cancela a task).
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

  it "formata o wire como Event#to_h em JSON (D5)" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    event = ev(:content, { delta: "x" })
    chunks = []

    Sync do
      collector = Async { described_class.new(subscription: sub).each { |c| chunks << c } }
      stream.emit(event)
      sub.close
      collector.wait
    end

    expect(chunks.first).to eq("data: #{JSON.generate(event.to_h)}\n\n")
  end

  it "preserva a ordem dos eventos" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    events = (1..3).map { |i| ev(:content, { delta: i.to_s }, { task_id: "t", seq: i }) }
    chunks = []

    Sync do
      collector = Async { described_class.new(subscription: sub).each { |c| chunks << c } }
      events.each { |e| stream.emit(e) }
      sub.close
      collector.wait
    end

    expect(chunks).to eq(events.map { |e| "data: #{JSON.generate(e.to_h)}\n\n" })
  end

  it "emite heartbeat após silêncio maior que o intervalo" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    chunks = []

    Sync do |task|
      collector = Async do
        described_class.new(subscription: sub, heartbeat: 0.05).each { |c| chunks << c }
      end
      task.sleep(0.15) # sem eventos: força ≥1 timeout de heartbeat
      sub.close
      collector.wait
    end

    expect(chunks).to include(": ping\n\n")
  end

  it "encerra o #each quando a subscription é fechada pelo chamador" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    finished = false

    Sync do
      collector = Async do
        described_class.new(subscription: sub).each { |_c| nil }
        finished = true
      end
      sub.close
      collector.wait
    end

    expect(finished).to be(true)
  end

  it "cliente desconecta: fecha a subscription, não propaga exceção, não cancela a task" do
    sub = SpySub.new([ev(:content, { delta: "x" })])

    Sync do
      expect do
        described_class.new(subscription: sub).each { |_c| raise "socket fechado" }
      end.not_to raise_error
    end

    expect(sub.closed).to be(true)
    expect(sub.cancelled).to be(false) # L4: execução pertence ao runtime
  end

  describe "cap de 1000 eventos por Subscription (doc 07 §5)" do
    it "fecha com :error local ao exceder o cap; emit nunca bloqueia" do
      stream = Harness::EventStream.new
      sub = stream.subscribe

      # 1001 emissões sem consumo: a 1001ª estoura o cap. `emit` é O(subscribers)
      # e nunca bloqueia — se bloqueasse, este laço travaria.
      1001.times { |i| stream.emit(Harness::Event.new(type: :content, data: { i: i }, meta: {})) }

      collected = []
      Sync { sub.each { |e| collected << e } }

      expect(collected.last.type).to eq(:error)
      expect(collected.last.to_h[:message]).to eq("subscription overflow")
    end
  end
end
