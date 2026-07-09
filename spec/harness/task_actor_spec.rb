# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::TaskActor do
  it "rejeita mensagem fora do enum" do
    Sync do
      actor = described_class.new(task_id: "t")
      expect { actor.post(:heartbeat) }.to raise_error(ArgumentError)
    end
  end

  it "drain! levanta CancelledError após post(:cancel)" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:cancel)
      expect { actor.drain! }.to raise_error(Harness::CancelledError)
    end
  end

  it "acumula :user_message (reservado) sem levantar" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:user_message, "oi")
      actor.drain!
      expect(actor.pending_user_messages).to eq(["oi"])
    end
  end

  it "drain! vazio retorna sem bloquear" do
    Sync do
      actor = described_class.new(task_id: "t")
      expect(actor.drain!).to be_nil
    end
  end

  it "drain! acumula user_message E levanta o cancel (ordem preservada)" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:user_message, "antes")
      actor.post(:cancel)
      expect { actor.drain! }.to raise_error(Harness::CancelledError)
      expect(actor.pending_user_messages).to eq(["antes"])
    end
  end

  it "run executa o bloco num fiber e retorna um Async::Task" do
    Sync do
      actor = described_class.new(task_id: "t")
      ran = false
      handle = actor.run { ran = true }
      actor.wait
      expect(ran).to be(true)
      expect(handle).to be_a(Async::Task)
    end
  end
end
