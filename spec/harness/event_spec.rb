# frozen_string_literal: true

RSpec.describe Harness::Event do
  describe "compatibilidade com a Fase 0" do
    it "constrói sem meta (default {})" do
      event = described_class.new(type: :content, data: { delta: "oi" })
      expect(event.meta).to eq({})
    end

    it "to_h mantém type e as chaves de data planas no topo + meta aditivo" do
      event = described_class.new(type: :done, data: { content: "oi" })
      expect(event.to_h).to eq(type: :done, content: "oi", meta: {})
    end

    it "reproduz o shape da Fase 0 para todos os tipos legados" do
      legados = {
        skill_activated: { name: "s" },
        tool_call: { name: "t", arguments: { q: 1 } },
        tool_result: { name: "t", result: "ok" },
        content: { delta: "oi" },
        done: { content: "fim" },
        error: { message: "boom" }
      }
      legados.each do |type, data|
        to_h = described_class.new(type: type, data: data).to_h
        # shape da Fase 0: { type: type }.merge(data) — planas no topo
        expect(to_h).to eq({ type: type }.merge(data).merge(meta: {}))
      end
    end
  end

  describe "meta" do
    it "carrega correlação em to_h[:meta]" do
      meta = { task_id: "t1", seq: 3, at: "2026-07-06T00:00:00Z" }
      event = described_class.new(type: :content, data: { delta: "x" }, meta: meta)
      expect(event.to_h[:meta]).to eq(meta)
    end

    it "compacta nils do meta" do
      event = described_class.new(
        type: :content, data: { delta: "x" },
        meta: { task_id: "t1", session_id: nil, seq: 1, at: nil }
      )
      expect(event.to_h[:meta]).to eq(task_id: "t1", seq: 1)
    end
  end

  it "é imutável (Data)" do
    event = described_class.new(type: :done, data: {})
    expect(event).to be_frozen
    expect(event).not_to respond_to(:type=)
  end
end
