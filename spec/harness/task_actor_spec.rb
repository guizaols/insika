# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::TaskActor do
  it "rejeita mensagem fora do enum" do
    Sync do
      actor = described_class.new(task_id: "t")
      expect { actor.post(:bogus) }.to raise_error(ArgumentError)
    end
  end

  it "aceita as mensagens da Fase 2 (approval/pause/resume/timeout/heartbeat)" do
    Sync do
      actor = described_class.new(task_id: "t")
      %i[approval pause resume timeout heartbeat].each do |m|
        expect { actor.post(m) }.not_to raise_error
      end
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

  # --- Fase 2: mailbox completa + suspensão ---------------------------------

  it "drain! seta pause_requested? no :pause e conta :heartbeat" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:pause)
      actor.post(:heartbeat)
      actor.post(:heartbeat)
      actor.drain!
      expect(actor.pause_requested?).to be(true)
      expect(actor.heartbeats).to eq(2)
    end
  end

  it "await retorna [:resume, nil] quando :resume é postado" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      result = nil
      waiter = top.async { result = actor.await(reason: :paused) }
      top.sleep(0.01)
      actor.post(:resume)
      waiter.wait
      expect(result).to eq([:resume, nil])
      expect(actor.pause_requested?).to be(false) # limpo ao entrar em await
    end
  end

  it "await retorna [:approval, decision] preservando o payload" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      result = nil
      waiter = top.async { result = actor.await(reason: :waiting) }
      top.sleep(0.01)
      actor.post(:approval, "approved")
      waiter.wait
      expect(result).to eq([:approval, "approved"])
    end
  end

  it "await consome resolução JÁ bufferizada (chegou antes da suspensão) sem bloquear" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:resume) # chega numa fronteira, antes do await
      actor.drain!        # bufferiza (não perde)
      expect(actor.await(reason: :paused)).to eq([:resume, nil])
    end
  end

  it "await levanta CancelledError quando :cancel chega durante a espera" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      raised = nil
      waiter = top.async do
        actor.await(reason: :paused)
      rescue Harness::CancelledError => e
        raised = e
      end
      top.sleep(0.01)
      actor.post(:cancel)
      waiter.wait
      expect(raised).to be_a(Harness::CancelledError)
    end
  end

  it "await levanta TimeoutError no :timeout (com stage)" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      raised = nil
      waiter = top.async do
        actor.await(reason: :approval_timeout)
      rescue Harness::TimeoutError => e
        raised = e
      end
      top.sleep(0.01)
      actor.post(:timeout, :approval_timeout)
      waiter.wait
      expect(raised).to be_a(Harness::TimeoutError)
      expect(raised.stage).to eq(:approval_timeout)
    end
  end
end
