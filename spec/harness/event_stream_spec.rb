# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::EventStream do
  subject(:stream) { described_class.new }

  def evt(type: :content, data: {}, meta: {})
    Harness::Event.new(type: type, data: data, meta: meta)
  end

  # Coleta os eventos de uma subscription num fiber consumidor até o close.
  def collect(parent, sub)
    got = []
    consumer = parent.async { sub.each { |e| got << e } }
    yield
    sub.close
    consumer.wait
    got
  end

  it "faz fan-out para 2 subscriptions sem filtro" do
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

  it "filtra por task_id" do
    Sync do |task|
      sub = stream.subscribe(task_id: "a")
      got = collect(task, sub) do
        stream.emit(evt(meta: { task_id: "a" }))
        stream.emit(evt(meta: { task_id: "b" }))
      end
      expect(got.map { |e| e.meta[:task_id] }).to eq(["a"])
    end
  end

  it "filtra por session_id" do
    Sync do |task|
      sub = stream.subscribe(session_id: "s1")
      got = collect(task, sub) do
        stream.emit(evt(meta: { session_id: "s1" }))
        stream.emit(evt(meta: { session_id: "s2" }))
      end
      expect(got.map { |e| e.meta[:session_id] }).to eq(["s1"])
    end
  end

  it "não entrega evento sem task no meta a subscriber com filtro de task; sem filtro recebe" do
    Sync do |task|
      filtered = stream.subscribe(task_id: "a")
      unfiltered = stream.subscribe
      got_f = []
      got_u = []
      cf = task.async { filtered.each { |e| got_f << e } }
      cu = task.async { unfiltered.each { |e| got_u << e } }
      stream.emit(evt(type: :session_created, meta: { session_id: "s" })) # sem task_id
      filtered.close
      unfiltered.close
      cf.wait
      cu.wait
      expect(got_f).to be_empty
      expect(got_u.size).to eq(1)
    end
  end

  it "itera exatamente até o close" do
    Sync do |task|
      sub = stream.subscribe
      got = collect(task, sub) { 3.times { |i| stream.emit(evt(data: { n: i })) } }
      expect(got.size).to eq(3)
    end
  end

  it "isola observador quebrado: emit não levanta e os demais recebem" do
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

  it "bufferiza para consumidor lento: emit não bloqueia (L4)" do
    Sync do |task|
      sub = stream.subscribe
      100.times { stream.emit(evt) } # nenhum consumidor ativo ainda
      got = []
      c = task.async { sub.each { |e| got << e } }
      sub.close
      c.wait
      expect(got.size).to eq(100)
    end
  end

  it "não entrega retroativo: subscribe depois do emit não recebe o passado" do
    Sync do |task|
      stream.emit(evt) # antes de qualquer subscribe
      sub = stream.subscribe
      got = collect(task, sub) { nil }
      expect(got).to be_empty
    end
  end

  it "emit sem subscribers é no-op" do
    expect(stream.emit(evt)).to be_nil
  end
end
