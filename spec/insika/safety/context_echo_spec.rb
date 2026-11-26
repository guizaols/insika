# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::ContextEcho do
  let(:inputs) do
    ["<memoria>\ntamanho: 38\n</memoria>\n\n<carrinho_vazio/>\n\nOi",
     "<historico_compras>\n- 1x Camiseta — R$ 99\n</historico_compras>\n\nTem no M?"]
  end

  it "cuts a context block the consumer sent, wherever it sits in the reply" do
    reply = "Oi! O que você procura hoje?\n\n<memoria>\nO cliente disse: Oi\n</memoria>"
    expect(described_class.cut(reply, inputs)).to eq(["Oi! O que você procura hoje?", 1])

    reply = "<historico_compras>\n- 1x Camiseta\n</historico_compras>\nTem sim, no M."
    expect(described_class.cut(reply, inputs)).to eq(["Tem sim, no M.", 1])
  end

  it "leaves markers and tags the consumer never sent as a block" do
    aggregate_failures do
      reply = "Tá no carrinho.\n\n<carrinho/>\n\nFechamos?\n<finalizar/>"
      expect(described_class.cut(reply, inputs)).to eq([reply, 0])

      reply = "Veja:\n<destaque>novo</destaque>"
      expect(described_class.cut(reply, inputs)).to eq([reply, 0])
      expect(described_class.cut("<carrinho_vazio/>", inputs)).to eq(["<carrinho_vazio/>", 0])
    end
  end
end
