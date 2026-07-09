# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::SessionStore do
  # Roda contra Memory; a paridade com SQLite é garantida pela suíte de
  # contrato da task 2 (doc 02 §7). Um smoke com SQLite ":memory:" fecha o loop.
  subject(:sessions) { described_class.new(store: backend) }

  let(:backend) { Harness::Stores::Memory.new }

  describe "#create" do
    it "retorna Session com defaults (uuid, arrays/hash vazios, timestamps ISO8601)" do
      session = sessions.create

      expect(session).to be_a(described_class::Session)
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(session.messages).to eq([])
      expect(session.vars).to eq({})
      expect(session.memory_refs).to eq([])
      expect(session.created_at).to eq(session.updated_at)
      expect { Time.iso8601(session.created_at) }.not_to raise_error
    end

    it "aceita id e vars explícitos, normalizando symbols" do
      session = sessions.create(id: "s-1", vars: { plan: :pro, nested: { a: 1 } })

      expect(session.id).to eq("s-1")
      expect(session.vars).to eq({ "plan" => "pro", "nested" => { "a" => 1 } })
    end

    it "levanta ArgumentError em id duplicado (não sobrescreve)" do
      sessions.create(id: "x")

      expect { sessions.create(id: "x") }.to raise_error(ArgumentError)
    end
  end

  describe "#find" do
    it "retorna nil para id inexistente" do
      expect(sessions.find("nope")).to be_nil
    end

    it "faz round-trip create->find com chaves string" do
      created = sessions.create(id: "s-2", vars: { a: 1 })
      found = sessions.find("s-2")

      expect(found.id).to eq("s-2")
      expect(found.vars).to eq({ "a" => 1 })
      expect(found.created_at).to eq(created.created_at)
    end
  end

  describe "#append_messages" do
    before { sessions.create(id: "s") }

    it "concatena preservando ordem e avança updated_at" do
      before_at = sessions.find("s").updated_at
      sessions.append_messages("s", { "role" => "user", "content" => "oi" })
      session = sessions.append_messages("s", { "role" => "assistant", "content" => "olá" })

      expect(session.messages.map { |m| m["content"] }).to eq(%w[oi olá])
      expect(session.messages.size).to eq(2)
      expect(session.updated_at >= before_at).to be(true)
    end

    it "normaliza mensagem com chaves symbol para chaves string" do
      session = sessions.append_messages("s", { role: :user, content: "oi" })

      expect(session.messages.first).to include("role" => "user", "content" => "oi")
    end

    it "carimba 'at' ISO8601 quando ausente e preserva quando presente" do
      sessions.append_messages("s", { role: :user, content: "sem at" })
      sessions.append_messages("s", { role: :user, content: "com at", at: "2020-01-01T00:00:00Z" })
      messages = sessions.find("s").messages

      expect { Time.iso8601(messages[0]["at"]) }.not_to raise_error
      expect(messages[1]["at"]).to eq("2020-01-01T00:00:00Z")
    end

    it "aceita um Array de mensagens de uma vez" do
      session = sessions.append_messages("s", [
                                            { role: :user, content: "a" },
                                            { role: :assistant, content: "b" }
                                          ])

      expect(session.messages.size).to eq(2)
    end

    it "levanta NotFoundError em sessão inexistente" do
      expect { sessions.append_messages("nope", { role: :user }) }
        .to raise_error(Harness::NotFoundError)
    end
  end

  describe "#update_vars" do
    before { sessions.create(id: "s", vars: { "a" => 1 }) }

    it "faz merge raso e avança updated_at" do
      session = sessions.update_vars("s", { b: 2 })

      expect(session.vars).to eq({ "a" => 1, "b" => 2 })
    end

    it "substitui inteiramente o valor de chave existente (merge raso)" do
      sessions.update_vars("s", { "nested" => { "x" => 1 } })
      session = sessions.update_vars("s", { nested: { y: 2 } })

      expect(session.vars["nested"]).to eq({ "y" => 2 })
    end

    it "levanta NotFoundError em sessão inexistente" do
      expect { sessions.update_vars("nope", { a: 1 }) }
        .to raise_error(Harness::NotFoundError)
    end
  end

  describe "#delete" do
    it "retorna true e remove sessão existente" do
      sessions.create(id: "s")

      expect(sessions.delete("s")).to be(true)
      expect(sessions.find("s")).to be_nil
    end

    it "retorna false para id inexistente (sem exceção)" do
      expect(sessions.delete("nope")).to be(false)
    end
  end

  describe "#each_id" do
    it "enumera ids sem o prefixo 'session:'" do
      %w[a b c].each { |id| sessions.create(id: id) }

      expect(sessions.each_id.to_a).to contain_exactly("a", "b", "c")
    end

    it "retorna um Enumerator sem bloco" do
      expect(sessions.each_id).to be_a(Enumerator)
    end

    it "não enxerga chaves de outro scope do backend (isolamento)" do
      sessions.create(id: "a")
      backend.set("other-scope", "session:intruso", { "id" => "intruso" })

      expect(sessions.each_id.to_a).to eq(["a"])
    end
  end

  describe "propagação de erro do backend (doc 02 §6)" do
    it "deixa StoreError propagar sem re-embrulhar" do
      # valor não-JSONable força o StoreError na escrita do backend (C22);
      # o SessionStore não deve capturar/re-embrulhar (doc 02 §6).
      sessions.create(id: "s")

      expect { sessions.update_vars("s", { obj: Object.new }) }
        .to raise_error(Harness::StoreError)
    end
  end

  describe "smoke contra Stores::SQLite ':memory:'" do
    it "fluxo create->append->find idêntico ao Memory" do
      require "sqlite3"
      sqlite = Harness::Stores::SQLite.new(path: ":memory:")
      store = described_class.new(store: sqlite)

      store.create(id: "s")
      store.append_messages("s", { role: :user, content: "oi" })
      session = store.find("s")

      expect(session.messages.first).to include("role" => "user", "content" => "oi")
      expect(session.messages.first["at"]).not_to be_nil
    ensure
      sqlite&.close
    end
  end
end
