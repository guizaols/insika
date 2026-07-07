# frozen_string_literal: true

# Suíte de contrato do Harness::Store (doc 01 §7).
# Todo backend passa EXATAMENTE esta suíte (L2: a suíte é honesta —
# um teste que passa em Memory passa em SQLite).
# O grupo que inclui deve definir `store` (backend vazio e pronto), ex.:
#
#   RSpec.describe Harness::Stores::Memory do
#     subject(:store) { described_class.new }
#     it_behaves_like "a harness store"
#   end
#
# Não inclua aqui casos específicos de backend (durabilidade de arquivo,
# WAL, concorrência) — esses são da task 4.
RSpec.shared_examples "a harness store" do
  describe "#get / #set (round-trip)" do
    it "C1 preserva Hash com chaves string" do # C1
      store.set("s", "k", { "a" => 1, "b" => [1, 2] })
      expect(store.get("s", "k")).to eq({ "a" => 1, "b" => [1, 2] })
    end

    it "C2 preserva Array" do # C2
      store.set("s", "k", [1, "x", true, nil])
      expect(store.get("s", "k")).to eq([1, "x", true, nil])
    end

    it "C3 preserva String" do # C3
      store.set("s", "k", "texto")
      expect(store.get("s", "k")).to eq("texto")
    end

    it "C4 preserva Integer" do # C4
      store.set("s", "k", 42)
      value = store.get("s", "k")
      expect(value).to eq(42)
      expect(value).to be_a(Integer)
    end

    it "C5 preserva Float" do # C5
      store.set("s", "k", 3.14)
      value = store.get("s", "k")
      expect(value).to eq(3.14)
      expect(value).to be_a(Float)
    end

    it "C6 preserva booleanos" do # C6
      store.set("s", "t", true)
      store.set("s", "f", false)
      expect(store.get("s", "t")).to be(true)
      expect(store.get("s", "f")).to be(false)
    end

    it "C7 preserva nil gravado sem exceção" do # C7
      store.set("s", "k", nil)
      expect(store.get("s", "k")).to be_nil
    end

    it "C8 converte Symbols (chaves e valores) em Strings" do # C8
      store.set("s", "k", { chave: :valor })
      expect(store.get("s", "k")).to eq({ "chave" => "valor" })
    end

    it "C9 retorna nil em chave ausente, nunca exceção" do # C9
      expect(store.get("s", "nao-existe")).to be_nil
    end

    it "C10 sobrescreve silenciosamente (last-write-wins)" do # C10
      store.set("s", "k", "primeiro")
      store.set("s", "k", "segundo")
      expect(store.get("s", "k")).to eq("segundo")
    end

    it "C11 set retorna o mesmo objeto passado (não o round-trip)" do # C11
      obj = { "a" => 1 }
      expect(store.set("s", "k", obj)).to equal(obj)
    end
  end

  describe "#delete" do
    it "C12 remove existente e retorna true" do # C12
      store.set("s", "k", 1)
      expect(store.delete("s", "k")).to be(true)
      expect(store.get("s", "k")).to be_nil
    end

    it "C13 retorna false para chave inexistente" do # C13
      expect(store.delete("s", "k")).to be(false)
    end
  end

  describe "#list" do
    it "C14 retorna chaves do scope ordenadas lexicograficamente" do # C14
      store.set("s", "b", 1)
      store.set("s", "a", 1)
      store.set("s", "c", 1)
      expect(store.list("s")).to eq(%w[a b c])
    end

    it "C15 filtra por prefixo com start_with? (não include?)" do # C15
      store.set("s", "task:1", 1)
      store.set("s", "task:2", 1)
      store.set("s", "checkpoint:1", 1)
      store.set("s", "my-task:1", 1) # armadilha: contém "task:" mas não começa
      expect(store.list("s", "task:")).to eq(%w[task:1 task:2])
    end

    it "C16 retorna [] para scope vazio" do # C16
      expect(store.list("s")).to eq([])
    end

    it "ordena lexicograficamente, não numericamente" do # edge case 2
      store.set("s", "task:10", 1)
      store.set("s", "task:2", 1)
      expect(store.list("s", "task:")).to eq(%w[task:10 task:2])
    end
  end

  describe "isolamento de scopes" do
    it "C17 mantém scopes independentes em get/list/delete" do # C17
      store.set("s1", "k", 1)
      store.set("s2", "k", 2)

      expect(store.get("s1", "k")).to eq(1)
      expect(store.get("s2", "k")).to eq(2)
      expect(store.list("s1")).to eq(%w[k])

      store.delete("s1", "k")
      expect(store.get("s2", "k")).to eq(2)
    end
  end

  describe "#transaction" do
    it "C18 retorna o valor do bloco" do # C18
      expect(store.transaction { 42 }).to eq(42)
    end

    it "C19 commita as escritas do bloco" do # C19
      store.transaction { store.set("s", "k", "commitado") }
      expect(store.get("s", "k")).to eq("commitado")
    end

    it "C20 faz rollback real de set E delete quando o bloco levanta" do # C20
      store.set("s", "manter", "antigo")
      store.set("s", "apagar", "existe")

      expect do
        store.transaction do
          store.set("s", "manter", "novo")
          store.delete("s", "apagar")
          raise "boom"
        end
      end.to raise_error("boom")

      # todos os efeitos do bloco desfeitos
      expect(store.get("s", "manter")).to eq("antigo")
      expect(store.get("s", "apagar")).to eq("existe")
    end

    it "C21 reusa a transação externa em aninhamento" do # C21
      store.set("s", "k", "antigo")

      expect do
        store.transaction do
          store.transaction { store.set("s", "k", "novo") }
          raise "boom"
        end
      end.to raise_error("boom")

      # rollback da externa desfaz o set da interna (sem erro de aninhamento)
      expect(store.get("s", "k")).to eq("antigo")
    end
  end

  describe "erros de serialização" do
    it "C22 levanta StoreError e não grava valor não serializável" do # C22
      expect do
        store.set("s", "k", Object.new)
      end.to raise_error(Harness::StoreError)
      expect(store.get("s", "k")).to be_nil
    end
  end
end
