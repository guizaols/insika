# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/queue"

RSpec.describe Harness::SessionActor do
  # Executor fake: run_serial registra start/done e BLOQUEIA num token de release
  # (simula o turno levando tempo), permitindo observar a serialização.
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

  it "serializa: o 2º turno só roda depois do 1º concluir (FIFO)" do
    Sync do |top|
      exec = FakeExec.new
      sa = described_class.new(session_id: "s", executor: exec, parent: top)
      sa.enqueue(task("t1"), profile: nil)
      sa.enqueue(task("t2"), profile: nil)
      top.sleep(0.02)

      expect(exec.events).to eq([[:start, "t1"]]) # só t1 começou
      expect(sa.running?).to be(true)
      expect(sa.depth).to eq(1)                   # t2 aguarda na fila

      exec.release.enqueue(:go)                   # conclui t1
      top.sleep(0.02)
      expect(exec.events).to eq([[:start, "t1"], [:done, "t1"], [:start, "t2"]])

      exec.release.enqueue(:go)                   # conclui t2
      top.sleep(0.02)
      expect(exec.events.last).to eq([:done, "t2"])
      sa.stop
    end
  end

  it "um turno que falha NÃO derruba o loop (o próximo roda)" do
    Sync do |top|
      exec = FakeExec.new(raise_on: "t1")
      sa = described_class.new(session_id: "s", executor: exec, parent: top)
      sa.enqueue(task("t1"), profile: nil)
      sa.enqueue(task("t2"), profile: nil)
      top.sleep(0.02)
      exec.release.enqueue(:go) # t1 levanta dentro do run_serial
      top.sleep(0.02)
      exec.release.enqueue(:go) # t2 segue normalmente
      top.sleep(0.02)
      expect(exec.events).to include([:start, "t2"], [:done, "t2"])
      sa.stop
    end
  end

  it "depth reflete a fila; running? false quando ociosa" do
    Sync do |top|
      exec = FakeExec.new
      sa = described_class.new(session_id: "s", executor: exec, parent: top)
      sa.enqueue(task("t1"), profile: nil)
      sa.enqueue(task("t2"), profile: nil)
      sa.enqueue(task("t3"), profile: nil)
      top.sleep(0.02)
      expect(sa.depth).to eq(2) # t1 rodando, t2/t3 na fila
      3.times { exec.release.enqueue(:go) }
      top.sleep(0.03)
      expect(sa.running?).to be(false)
      expect(sa.depth).to eq(0)
      sa.stop
    end
  end
end
