# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::CheckpointStore do
  # Contra Memory (rollback real, task 03) + smoke SQLite ":memory:" (doc 02 §7).
  subject(:checkpoints) { described_class.new(store: backend) }

  let(:backend) { Harness::Stores::Memory.new }

  # Constrói um Checkpoint completo do turno n.
  def checkpoint(task_id: "t", turn: 1, side_effects: [], messages: nil)
    Harness::Checkpoint.new(
      task_id: task_id,
      turn: turn,
      session_id: "s-1",
      agent_id: "sales",
      messages: messages || [{ "role" => "user", "content" => "oi" }],
      completed_side_effects: side_effects,
      created_at: nil
    )
  end

  describe "#save / #find round-trip" do
    it "devolve os campos iguais, turn Integer e chaves string em messages" do
      saved = checkpoints.save(checkpoint(turn: 1, messages: [{ role: :user, content: "oi" }]))
      found = checkpoints.find("t", turn: 1)

      expect(found.turn).to be_a(Integer).and eq(1)
      expect(found.session_id).to eq("s-1")
      expect(found.agent_id).to eq("sales")
      expect(found.messages).to eq([{ "role" => "user", "content" => "oi" }])
      expect(found.created_at).to eq(saved.created_at)
      expect { Time.iso8601(found.created_at) }.not_to raise_error
    end

    it "carimba created_at quando ausente no Checkpoint recebido" do
      saved = checkpoints.save(checkpoint(turn: 1))

      expect { Time.iso8601(saved.created_at) }.not_to raise_error
    end
  end

  describe "monotonicidade do turn" do
    before { checkpoints.save(checkpoint(turn: 2)) }

    it "rejeita save de turn repetido" do
      expect { checkpoints.save(checkpoint(turn: 2)) }.to raise_error(ArgumentError)
    end

    it "rejeita save de turn menor" do
      expect { checkpoints.save(checkpoint(turn: 1)) }.to raise_error(ArgumentError)
    end

    it "não escreve nada ao rejeitar (transação)" do
      expect { checkpoints.save(checkpoint(turn: 1)) }.to raise_error(ArgumentError)
      expect(checkpoints.latest("t").turn).to eq(2)
    end
  end

  describe "#latest" do
    it "retorna o maior turn (sequencial)" do
      [1, 2, 3].each { |n| checkpoints.save(checkpoint(turn: n)) }

      expect(checkpoints.latest("t").turn).to eq(3)
    end

    it "retorna o maior turn com turnos esparsos (3, 7, 12)" do
      [3, 7, 12].each { |n| checkpoints.save(checkpoint(turn: n)) }

      expect(checkpoints.latest("t").turn).to eq(12)
    end

    it "ordena numericamente com turn >= 10 (10 > 9, não lexicográfico)" do
      checkpoints.save(checkpoint(turn: 9))
      checkpoints.save(checkpoint(turn: 10))

      expect(checkpoints.latest("t").turn).to eq(10)
    end

    it "retorna nil para task sem checkpoint" do
      expect(checkpoints.latest("nope")).to be_nil
      expect(checkpoints.find("nope", turn: 1)).to be_nil
    end
  end

  describe "side-effects" do
    it "record_side_effect é idempotente" do
      checkpoints.record_side_effect("t", turn: 1, tool_call_id: "call_a")
      checkpoints.record_side_effect("t", turn: 1, tool_call_id: "call_a")

      expect(checkpoints.side_effects("t", turn: 1)).to eq(["call_a"])
    end

    it "side_effects vazio quando nada registrado" do
      expect(checkpoints.side_effects("t", turn: 1)).to eq([])
    end

    it "side_effects = chave avulsa ∪ completed_side_effects do checkpoint" do
      checkpoints.record_side_effect("t", turn: 5, tool_call_id: "call_spill")
      # grava o checkpoint do turno 5 com um id já consolidado nele (turno 5 sem
      # avulsa própria absorvida — a de turno 4 é a absorvida no save do 5)
      checkpoints.save(checkpoint(turn: 5, side_effects: ["call_cp"]))

      expect(checkpoints.side_effects("t", turn: 5)).to contain_exactly("call_spill", "call_cp")
    end
  end

  describe "consolidação no save (chave avulsa do turno n absorvida no save do n+1)" do
    it "inclui os ids da avulsa e apaga a chave avulsa do backend" do
      checkpoints.record_side_effect("t", turn: 3, tool_call_id: "call_x")
      saved = checkpoints.save(checkpoint(turn: 4))

      expect(saved.completed_side_effects).to include("call_x")
      expect(backend.get("checkpoints", "sideeffects:t:turn:3")).to be_nil
    end

    it "faz a união com os ids que já vieram no Checkpoint" do
      checkpoints.record_side_effect("t", turn: 3, tool_call_id: "call_spill")
      saved = checkpoints.save(checkpoint(turn: 4, side_effects: ["call_cp"]))

      expect(saved.completed_side_effects).to contain_exactly("call_spill", "call_cp")
    end

    it "consolida com [] quando o turno não teve side-effects" do
      saved = checkpoints.save(checkpoint(turn: 1, side_effects: ["call_only_cp"]))

      expect(saved.completed_side_effects).to eq(["call_only_cp"])
    end
  end

  describe "crash-consistency (D4, doc 02 §7)" do
    # Backend que delega ao Memory mas cujo `delete` levanta — a exceção ocorre
    # DENTRO da transação de save, DEPOIS de o novo checkpoint já ter sido
    # escrito (set). O rollback real (task 03) deve desfazer o set e preservar a
    # chave avulsa.
    let(:faulty) do
      Class.new do
        attr_reader :sets

        def initialize(inner)
          @inner = inner
          @sets = 0
        end

        def get(*a) = @inner.get(*a)

        def set(*a)
          @sets += 1
          @inner.set(*a)
        end

        def list(*a) = @inner.list(*a)
        def transaction(&blk) = @inner.transaction(&blk)
        def delete(*) = raise Harness::StoreError, "falha simulada no delete"
      end.new(backend)
    end

    it "exceção no meio do save deixa o checkpoint anterior intacto e a avulsa preservada" do
      store = described_class.new(store: faulty)
      # turno 3 já commitado (via backend limpo, sem passar pelo delete faulty)
      described_class.new(store: backend).save(checkpoint(turn: 3))
      backend.set("checkpoints", "sideeffects:t:turn:3", ["call_pending"])

      expect { store.save(checkpoint(turn: 4)) }.to raise_error(Harness::StoreError)

      # precondição load-bearing: o set do turno 4 FOI aplicado antes do delete
      # levantar — só assim o "latest volta a 3" prova rollback real (senão
      # seria falso-verde por a escrita nunca ter acontecido).
      expect(faulty.sets).to eq(1)
      # latest volta ao turno 3 (o set do turno 4 foi revertido)
      expect(checkpoints.latest("t").turn).to eq(3)
      expect(checkpoints.find("t", turn: 4)).to be_nil
      # a chave avulsa não foi absorvida/apagada
      expect(backend.get("checkpoints", "sideeffects:t:turn:3")).to eq(["call_pending"])
    end
  end

  describe "#prune" do
    it "keep: 1 preserva só o maior turn" do
      (1..4).each { |n| checkpoints.save(checkpoint(turn: n)) }
      checkpoints.prune("t", keep: 1)

      expect(checkpoints.latest("t").turn).to eq(4)
      expect([1, 2, 3].map { |n| checkpoints.find("t", turn: n) }).to all(be_nil)
    end

    it "keep: 2 preserva os dois maiores turns" do
      (1..4).each { |n| checkpoints.save(checkpoint(turn: n)) }
      checkpoints.prune("t", keep: 2)

      expect(checkpoints.find("t", turn: 3)).not_to be_nil
      expect(checkpoints.find("t", turn: 4)).not_to be_nil
      expect(checkpoints.find("t", turn: 2)).to be_nil
    end

    it "é no-op com menos checkpoints que keep" do
      checkpoints.save(checkpoint(turn: 1))
      checkpoints.prune("t", keep: 1)

      expect(checkpoints.find("t", turn: 1)).not_to be_nil
    end

    it "limpa chaves avulsas de turnos anteriores ao menor mantido" do
      (1..3).each { |n| checkpoints.save(checkpoint(turn: n)) }
      backend.set("checkpoints", "sideeffects:t:turn:1", ["lixo"])
      checkpoints.prune("t", keep: 1) # mantém só turno 3

      expect(backend.get("checkpoints", "sideeffects:t:turn:1")).to be_nil
    end
  end

  describe "isolamento entre tasks" do
    it "checkpoints e avulsas de task_a não afetam task_b" do
      checkpoints.save(checkpoint(task_id: "a", turn: 5))
      checkpoints.record_side_effect("a", turn: 5, tool_call_id: "call_a")
      checkpoints.save(checkpoint(task_id: "b", turn: 1))

      expect(checkpoints.latest("b").turn).to eq(1)
      expect(checkpoints.side_effects("b", turn: 5)).to eq([])

      checkpoints.prune("a", keep: 1)
      expect(checkpoints.latest("b").turn).to eq(1) # prune de "a" não tocou "b"
    end
  end

  describe "smoke contra Stores::SQLite ':memory:'" do
    it "save->latest->record->save->prune idêntico ao Memory" do
      require "sqlite3"
      sqlite = Harness::Stores::SQLite.new(path: ":memory:")
      store = described_class.new(store: sqlite)

      store.save(checkpoint(turn: 1))
      store.record_side_effect("t", turn: 1, tool_call_id: "call_x")
      saved = store.save(checkpoint(turn: 2))

      expect(store.latest("t").turn).to eq(2)
      expect(saved.completed_side_effects).to include("call_x")

      store.prune("t", keep: 1)
      expect(store.find("t", turn: 1)).to be_nil
    ensure
      sqlite&.close
    end
  end
end
