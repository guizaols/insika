# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::TaskStore do
  # Contra Memory; paridade com SQLite garantida pela suíte de contrato da
  # task 2 (doc 02 §7) + um smoke SQLite ":memory:".
  subject(:tasks) { described_class.new(store: backend) }

  let(:backend) { Harness::Stores::Memory.new }
  let(:command) { { type: "send_message", payload: {}, meta: {} } }

  describe "matriz completa de transições (doc 02 §7)" do
    # Conjunto válido transcrito da tabela do doc 02 §2 (12 pares ✓).
    valid = {
      queued: %i[running cancelled],
      running: %i[waiting paused completed failed cancelled],
      waiting: %i[running cancelled failed],
      paused: %i[running cancelled]
    }
    valid.default = []

    # Prepara uma task no estado de origem gravando o registro direto no
    # backend (aceitável em teste de store) — evita depender de caminhos válidos.
    def seed_in_state(state)
      id = "t-#{state}"
      now = "2020-01-01T00:00:00Z"
      backend.set("tasks", "task:#{id}", {
                    "id" => id, "status" => state.to_s, "command" => {},
                    "session_id" => nil, "executions" => [],
                    "mailbox_state" => { "pending" => [] },
                    "claimed_by" => nil, "claim_expires_at" => nil,
                    "created_at" => now, "updated_at" => now
                  })
      id
    end

    described_class::STATUSES.each do |from|
      described_class::STATUSES.each do |to|
        if valid[from].include?(to)
          it "#{from} -> #{to} transita" do
            id = seed_in_state(from)
            expect(tasks.transition(id, to: to).status).to eq(to)
          end
        else
          it "#{from} -> #{to} levanta ArgumentError" do
            id = seed_in_state(from)
            expect { tasks.transition(id, to: to) }.to raise_error(ArgumentError)
          end
        end
      end
    end

    it "cobre os 49 pares (12 válidos, 37 inválidos)" do
      valid_count = described_class::STATUSES.sum { |s| valid[s].size }
      expect(valid_count).to eq(12)
      expect(described_class::STATUSES.size**2).to eq(49)
    end
  end

  describe "#create" do
    it "retorna Task com defaults" do
      task = tasks.create(command: command)

      expect(task.status).to eq(:queued)
      expect(task.executions).to eq([])
      expect(task.mailbox_state).to eq({ "pending" => [] })
      expect(task.claimed_by).to be_nil
      expect(task.claim_expires_at).to be_nil
      expect { Time.iso8601(task.created_at) }.not_to raise_error
    end

    it "levanta ArgumentError em id duplicado" do
      tasks.create(command: command, id: "x")

      expect { tasks.create(command: command, id: "x") }.to raise_error(ArgumentError)
    end

    it "normaliza command Hash com symbols para chaves string" do
      task = tasks.create(command: { type: :send_message, payload: { a: 1 } })

      expect(task.command).to eq({ "type" => "send_message", "payload" => { "a" => 1 } })
    end

    it "aceita objeto que responde a to_h (ex.: Harness::Command futura)" do
      command_like = Data.define(:type, :payload, :meta).new(
        type: "send_message", payload: {}, meta: {}
      )
      task = tasks.create(command: command_like)

      expect(task.command).to eq({ "type" => "send_message", "payload" => {}, "meta" => {} })
    end
  end

  describe "claim reservado (D7)" do
    it "mantém claimed_by/claim_expires_at nil após create + transições + executions" do
      id = tasks.create(command: command, id: "t").id
      tasks.begin_execution(id)
      tasks.transition(id, to: :running)
      tasks.finish_execution(id, outcome: "completed")
      tasks.transition(id, to: :completed)

      record = backend.get("tasks", "task:t")
      expect(record["claimed_by"]).to be_nil
      expect(record["claim_expires_at"]).to be_nil
    end
  end

  describe "#begin_execution / #finish_execution" do
    let(:id) { tasks.create(command: command, id: "t").id }

    it "numera attempts e preserva o histórico (append-only)" do
      tasks.begin_execution(id)
      tasks.finish_execution(id, outcome: "failed")
      task = tasks.begin_execution(id)

      expect(task.executions.map(&:attempt)).to eq([1, 2])
      expect(task.executions.first.outcome).to eq("failed")
      expect(task.executions.first.finished_at).not_to be_nil
    end

    it "begin com Execution aberta levanta ArgumentError" do
      tasks.begin_execution(id)

      expect { tasks.begin_execution(id) }.to raise_error(ArgumentError)
    end

    it "finish fecha a corrente sem tocar em status" do
      tasks.begin_execution(id)
      task = tasks.finish_execution(id, outcome: "completed")

      expect(task.executions.last.finished_at).not_to be_nil
      expect(task.executions.last.outcome).to eq("completed")
      expect(task.status).to eq(:queued)
    end

    it "finish sem Execution aberta levanta ArgumentError" do
      expect { tasks.finish_execution(id, outcome: "x") }.to raise_error(ArgumentError)
    end
  end

  describe "#transition com error:" do
    let(:id) { tasks.create(command: command, id: "t").id }
    let(:err) { { class: "RuntimeError", message: "boom", stage: :provider } }

    it "fecha a Execution aberta gravando o erro (chaves string)" do
      tasks.begin_execution(id)
      tasks.transition(id, to: :running)
      task = tasks.transition(id, to: :failed, error: err)

      execution = task.executions.last
      expect(execution.outcome).to eq("failed")
      expect(execution.finished_at).not_to be_nil
      expect(execution.error).to eq(
        { "class" => "RuntimeError", "message" => "boom", "stage" => "provider" }
      )
    end

    it "sem Execution aberta transiciona e ignora o error: (não levanta)" do
      task = tasks.transition(id, to: :cancelled, error: err)

      expect(task.status).to eq(:cancelled)
      expect(task.executions).to eq([])
    end
  end

  describe "#running_or_interrupted" do
    it "retorna só as tasks em running/waiting/paused" do
      # cobre os 7 estados, chegando a cada um por caminho válido
      tasks.create(command: command, id: "q") # queued
      tasks.transition(tasks.create(command: command, id: "r").id, to: :running)
      w = tasks.create(command: command, id: "w").id
      tasks.transition(w, to: :running)
      tasks.transition(w, to: :waiting)
      p = tasks.create(command: command, id: "p").id
      tasks.transition(p, to: :running)
      tasks.transition(p, to: :paused)
      tasks.transition(tasks.create(command: command, id: "c").id, to: :cancelled)
      done = tasks.create(command: command, id: "d").id
      tasks.transition(done, to: :running)
      tasks.transition(done, to: :completed)

      expect(tasks.running_or_interrupted.map(&:id)).to contain_exactly("r", "w", "p")
    end

    it "retorna [] quando não há tasks" do
      expect(tasks.running_or_interrupted).to eq([])
    end
  end

  describe "borda de tipos e consultas" do
    it "expõe status como Symbol após find" do
      tasks.create(command: command, id: "t")

      expect(tasks.find("t").status).to eq(:queued)
    end

    it "find inexistente -> nil" do
      expect(tasks.find("nope")).to be_nil
    end

    it "each_id: ids sem prefixo e Enumerator sem bloco" do
      %w[a b c].each { |id| tasks.create(command: command, id: id) }

      expect(tasks.each_id.to_a).to contain_exactly("a", "b", "c")
      expect(tasks.each_id).to be_a(Enumerator)
    end
  end

  describe "NotFoundError em id inexistente" do
    it "transition" do
      expect { tasks.transition("nope", to: :running) }.to raise_error(Harness::NotFoundError)
    end

    it "begin_execution" do
      expect { tasks.begin_execution("nope") }.to raise_error(Harness::NotFoundError)
    end

    it "finish_execution" do
      expect { tasks.finish_execution("nope", outcome: "x") }.to raise_error(Harness::NotFoundError)
    end
  end

  describe "propagação de erro do backend (doc 02 §6)" do
    it "deixa StoreError propagar sem re-embrulhar" do
      # command não-JSONable força StoreError na escrita (C22); o TaskStore não
      # captura/re-embrulha (doc 02 §6).
      expect { tasks.create(command: { obj: Object.new }) }
        .to raise_error(Harness::StoreError)
    end
  end

  describe "smoke contra Stores::SQLite ':memory:'" do
    it "fluxo create->transition->begin->finish idêntico ao Memory" do
      require "sqlite3"
      sqlite = Harness::Stores::SQLite.new(path: ":memory:")
      store = described_class.new(store: sqlite)

      id = store.create(command: command, id: "t").id
      store.begin_execution(id)
      store.transition(id, to: :running)
      task = store.finish_execution(id, outcome: "completed")

      expect(task.status).to eq(:running)
      expect(task.executions.last.outcome).to eq("completed")
    ensure
      sqlite&.close
    end
  end
end
