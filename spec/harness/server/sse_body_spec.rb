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

  # SSEBody é um STREAMING body do Rack 3: dirige-se por `#call(stream)`, onde
  # `stream` responde a #write/#close (o SSEStreamDouble coleta os frames). Isso
  # espelha o Protocol::HTTP::Body::Stream que o protocol-rack passa em produção.
  it "formata o wire como Event#to_h em JSON (D5)" do
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

  it "honra o serialize: injetado e pula eventos que ele mapeia p/ nil" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    fs = SSEStreamDouble.new
    # serializer custom: só :content vira frame; o resto é pulado (nil).
    serialize = ->(e) { e.type == :content ? "X:#{e.data[:delta]}\n\n" : nil }

    Sync do
      collector = Async { described_class.new(subscription: sub, serialize: serialize).call(fs) }
      stream.emit(ev(:content, { delta: "a" }))
      stream.emit(ev(:task_started))            # -> nil, pulado
      stream.emit(ev(:content, { delta: "b" }))
      sub.close
      collector.wait
    end

    expect(fs.chunks).to eq(["X:a\n\n", "X:b\n\n"])
  end

  it "preserva a ordem dos eventos" do
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

  it "emite heartbeat após silêncio maior que o intervalo" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    fs = SSEStreamDouble.new

    Sync do |task|
      collector = Async { described_class.new(subscription: sub, heartbeat: 0.05).call(fs) }
      task.sleep(0.15) # sem eventos: força ≥1 timeout de heartbeat
      sub.close
      collector.wait
    end

    expect(fs.chunks).to include(": ping\n\n")
  end

  it "encerra o #call quando a subscription é fechada pelo chamador" do
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

  it "cliente desconecta: fecha a subscription, não propaga exceção, não cancela a task" do
    sub = SpySub.new([ev(:content, { delta: "x" })])
    fs = SSEStreamDouble.new(raise_on_write: true) # stream.write levanta = socket fechado

    Sync do
      expect do
        described_class.new(subscription: sub).call(fs)
      end.not_to raise_error
    end

    expect(sub.closed).to be(true)
    expect(sub.cancelled).to be(false) # L4: execução pertence ao runtime
    expect(fs.closed?).to be(true)     # o body sempre fecha o stream
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
