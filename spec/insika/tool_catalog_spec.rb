# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::ToolCatalog do
  # Double that only responds to :description — without inheriting RubyLLM::Tool (duck typing).
  FakeTool = Struct.new(:description)

  let(:registry) { Insika::ToolRegistry.new }

  def catalog = described_class.new(tool_registry: registry)

  describe "#all" do
    it "preserves the registered MCP origin" do
      registry.register("execute_sql", plugin: "mcp:metabase") { FakeTool.new("Runs SQL") }
      expect(catalog.all.first.plugin).to eq("mcp:metabase")
    end

    it "one Entry(name, description) per registry entry, in registry order" do
      registry.register("send_email") { FakeTool.new("Sends an e-mail to the recipient") }
      registry.register("fetch_page") { FakeTool.new("Downloads a web page") }
      entries = catalog.all
      expect(entries.map(&:name)).to eq(%w[send_email fetch_page])
      expect(entries.first.description).to eq("Sends an e-mail to the recipient")
    end

    it "reads the description via a factory instance (duck typing)" do
      registry.register("t") { FakeTool.new("desc") }
      expect(catalog.all.first.description).to eq("desc")
    end

    it "description nil -> '' (never nil)" do
      registry.register("t") { FakeTool.new(nil) }
      expect(catalog.all.first.description).to eq("")
    end

    it "empty catalog -> []" do
      expect(catalog.all).to eq([])
    end
  end

  describe "#subset" do
    before do
      registry.register("a") { FakeTool.new("aa") }
      registry.register("b") { FakeTool.new("bb") }
    end

    it "returns only the requested entries" do
      expect(catalog.subset(["a"]).map(&:name)).to eq(["a"])
    end

    it "ignores unknown names without error" do
      expect(catalog.subset(%w[a inexistente]).map(&:name)).to eq(["a"])
    end

    it "subset([]) / subset(nil) -> []" do
      expect(catalog.subset([])).to eq([])
      expect(catalog.subset(nil)).to eq([])
    end
  end

  describe "#search" do
    before do
      registry.register("send_email") { FakeTool.new("Sends a message to the recipient") }
      registry.register("create_invoice") { FakeTool.new("Generates a PDF invoice") }
    end

    it "matches by name" do
      expect(catalog.search("email").map(&:name)).to eq(["send_email"])
    end

    it "matches by description only" do
      expect(catalog.search("recipient").map(&:name)).to eq(["send_email"])
    end

    it "empty / nil / whitespace-only query -> []" do
      expect(catalog.search("")).to eq([])
      expect(catalog.search(nil)).to eq([])
      expect(catalog.search("   ")).to eq([])
    end

    it "within: restricts the universe (a tool outside the slice does not appear)" do
      expect(catalog.search("invoice", within: ["send_email"])).to eq([])
    end

    it "ranking: a name match comes before a description-only match" do
      registry.register("report") { FakeTool.new("faz um email resumido") } # 'email' in the desc
      # 'email' hits the name of send_email and only the desc of report
      expect(catalog.search("email").map(&:name)).to eq(%w[send_email report])
    end

    it "a score tie preserves the original order of the universe" do
      reg = Insika::ToolRegistry.new
      reg.register("z_tool") { FakeTool.new("faz xyz") }
      reg.register("a_tool") { FakeTool.new("faz xyz") }
      cat = described_class.new(tool_registry: reg)
      # both hit only the desc ('xyz'), equal score -> registration order (z before a)
      expect(cat.search("xyz").map(&:name)).to eq(%w[z_tool a_tool])
    end

    it "compares words by their stem, so a verb form meets its noun" do
      registry.register("list_products") { FakeTool.new("Lista os produtos do catálogo da loja.") }
      # "listar" is not a substring of "Lista", but they share the stem
      expect(catalog.search("listar").map(&:name)).to eq(["list_products"])
    end

    it "a query word equal to a tool name puts that tool first" do
      registry.register("send_email_report") { FakeTool.new("Sends the e-mail report to the recipient") }
      # send_email_report hits more words (report x2, recipient), but the name asked wins
      expect(catalog.search("recipient report create_invoice").map(&:name).first).to eq("create_invoice")
    end

    it "several exact names in one query all come first" do
      registry.register("report") { FakeTool.new("Sends a report to the recipient") }
      names = catalog.search("send_email create_invoice recipient").map(&:name)
      expect(names.first(2)).to contain_exactly("send_email", "create_invoice")
    end

    it "a word every tool shares cannot outrank a rare one (IDF)" do
      reg = Insika::ToolRegistry.new
      reg.register("store_hours") { FakeTool.new("Horário de atendimento da loja da sessão") }
      reg.register("store_faq") { FakeTool.new("FAQ da loja da sessão, da categoria pedida") }
      reg.register("queue_state") { FakeTool.new("Estado das filas do Sidekiq da loja") }
      cat = described_class.new(tool_registry: reg)
      # by raw count the three tie; "da"/"loja" are in every description, "sidekiq" in one
      expect(cat.search("da loja da sessão sidekiq").map(&:name).first).to eq("queue_state")
    end

    it "the description's first sentence outweighs the rest" do
      reg = Insika::ToolRegistry.new
      reg.register("switch_a") { FakeTool.new("Turns the banner on or off. Use after list_faqs, not for FAQs.") }
      reg.register("switch_b") { FakeTool.new("Turns a FAQ on or off. The panel asks for approval.") }
      cat = described_class.new(tool_registry: reg)
      expect(cat.search("turn faq off").map(&:name)).to eq(%w[switch_b switch_a])
    end

    it "limit: caps the result at the best matches" do
      registry.register("send_sms") { FakeTool.new("Sends a text message to the recipient") }
      expect(catalog.search("sends recipient", limit: 1).map(&:name)).to eq(["send_email"])
      expect(catalog.search("sends recipient").map(&:name)).to eq(%w[send_email send_sms])
    end

    # Review of insika#2: a word shorter than the stem only met itself, so "tag" lost list_tags.
    it "a short word meets the longer words it starts" do
      registry.register("list_tags") { FakeTool.new("Lists the tags of the store.") }
      registry.register("list_faqs") { FakeTool.new("Lists the FAQs of the store.") }
      expect(catalog.search("tag").map(&:name)).to eq(["list_tags"])
      expect(catalog.search("faq").map(&:name)).to eq(["list_faqs"])
    end

    it "the word itself outranks a word that only shares its stem" do
      reg = Insika::ToolRegistry.new
      reg.register("configure_store") { FakeTool.new("Configure the store settings.") }
      reg.register("confirm_order") { FakeTool.new("Confirmar o pedido do cliente.") }
      cat = described_class.new(tool_registry: reg)
      # "confirmar" and "configure" share "confi"
      expect(cat.search("confirmar").map(&:name)).to eq(%w[confirm_order configure_store])
    end

    it "a tool named only with one-letter words is still found by its exact name" do
      registry.register("a_b") { FakeTool.new("Tool with a short name") }
      expect(catalog.search("a_b").map(&:name)).to eq(["a_b"])
    end

    it "tools asked for by exact name all come back, past the limit" do
      registry.register("send_sms") { FakeTool.new("Sends a text message to the recipient") }
      names = catalog.search("send_email create_invoice send_sms", limit: 2).map(&:name)
      expect(names).to contain_exactly("send_email", "create_invoice", "send_sms")
    end

    it "the limit counts the exact names, then fills with the closest by description" do
      registry.register("send_sms") { FakeTool.new("Sends a text message to the recipient") }
      expect(catalog.search("create_invoice recipient", limit: 2).map(&:name)).to eq(%w[create_invoice send_email])
    end

    # Review r2 of insika#2: the matched name was also read as words, so "send_email"
    # brought every tool saying "send" or "email" and 4 extra schemas per search.
    it "a query of exact names brings only those tools" do
      registry.register("send_email_report") { FakeTool.new("Emails the weekly report") }
      registry.register("send_sms") { FakeTool.new("Sends a text message to the recipient") }
      expect(catalog.search("send_email", limit: 8).map(&:name)).to eq(["send_email"])
    end

    it "a plural meets its singular" do
      reg = Insika::ToolRegistry.new
      reg.register("list_tag") { FakeTool.new("Lista a tag da loja.") }
      cat = described_class.new(tool_registry: reg)
      expect(cat.search("tags").map(&:name)).to eq(["list_tag"])
      expect(cat.search("lojas").map(&:name)).to eq(["list_tag"])
    end

    it "query words sharing a stem all count as words, in any order" do
      reg = Insika::ToolRegistry.new
      reg.register("configure_store") { FakeTool.new("Configure the store settings.") }
      reg.register("confirm_order") { FakeTool.new("Confirmar o pedido do cliente.") }
      reg.register("export_orders") { FakeTool.new("Listagem dos pedidos.") }
      reg.register("list_orders") { FakeTool.new("Lista os pedidos.") }
      cat = described_class.new(tool_registry: reg)
      both = %w[configure_store confirm_order]
      expect(cat.search("configure confirmar", limit: 2).map(&:name)).to eq(both)
      expect(cat.search("confirmar configure", limit: 2).map(&:name)).to eq(both)
      # "lista" is kept next to "listar": the tool saying "Lista" scores the whole word
      expect(cat.search("listar lista").map(&:name).first).to eq("list_orders")
    end

    it "punctuation and one-letter words do not become terms" do
      expect(catalog.search("(e) , .")).to eq([])
      expect(catalog.search("(send_email)").map(&:name).first).to eq("send_email")
    end

    it "reload drops the word index, so a changed description is searchable" do
      desc = "Sends a message"
      reg = Insika::ToolRegistry.new
      reg.register("notify") { FakeTool.new(desc) }
      cat = described_class.new(tool_registry: reg)
      expect(cat.search("webhook")).to eq([])
      desc = "Calls the webhook"
      expect(cat.reload.search("webhook").map(&:name)).to eq(["notify"])
    end
  end

  describe "#format_for_prompt" do
    before { registry.register("send_email") { FakeTool.new("Envia e-mail") } }

    it "includes <available_tools>, name, description and the tool_search instruction" do
      out = catalog.format_for_prompt(catalog.all)
      expect(out).to include("<available_tools>")
      expect(out).to include(%(name="send_email"))
      expect(out).to include("Envia e-mail")
      expect(out).to include("tool_search")
    end

    it "lists only the first sentence, capped at 120 chars" do
      registry.register("report") { FakeTool.new("Relatório de vendas. Detalhes longos que ficam de fora.") }
      registry.register("long") { FakeTool.new("x" * 300) }
      out = catalog.format_for_prompt(catalog.all)
      expect(out).to include(%(<tool name="report">Relatório de vendas.</tool>))
      expect(out).not_to include("Detalhes longos")
      expect(out[/<tool name="long">(.*)<\/tool>/, 1].length).to eq(120)
    end

    it "format_for_prompt([]) -> ''" do
      expect(catalog.format_for_prompt([])).to eq("")
    end
  end

  it "lazy: does not instantiate any tool on construction (only on the 1st query)" do
    instantiations = 0
    registry.register("t") { instantiations += 1; FakeTool.new("desc") }
    cat = described_class.new(tool_registry: registry)
    expect(instantiations).to eq(0)  # boot does not touch the tool
    cat.all
    expect(instantiations).to eq(1)  # instantiated on the 1st use
    cat.all
    expect(instantiations).to eq(1)  # memoized — does not reinstantiate
  end

  it "a factory that raises propagates on the 1st use (where the Executor would also catch it)" do
    registry.register("boom") { raise "registro quebrado" }
    cat = described_class.new(tool_registry: registry)
    expect { cat.all }.to raise_error(/registro quebrado/)
  end
end
