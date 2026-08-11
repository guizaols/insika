# frozen_string_literal: true

require "spec_helper"

# Evals golden loader. Data-file validation: a malformed golden
# must fail LOUD at load, never silently drop (a dropped case = a hole in the net).
RSpec.describe Insika::Evals::GoldenLoader do
  def build(overrides = {})
    described_class.build({
      "id" => "c1", "agent" => "bia", "turns" => [{ "user" => "oi" }], "expect" => {}
    }.merge(overrides))
  end

  it "builds a valid golden" do
    g = build
    expect(g.id).to eq("c1")
    expect(g.agent).to eq("bia")
    expect(g.user_turns).to eq(["oi"])
  end

  it "requires id, agent and non-empty turns" do
    expect { build("id" => "") }.to raise_error(described_class::InvalidGolden, /'id' is required/)
    expect { build("agent" => nil) }.to raise_error(described_class::InvalidGolden, /'agent' is required/)
    expect { build("turns" => []) }.to raise_error(described_class::InvalidGolden, /non-empty array/)
    expect { build("turns" => [{ "usr" => "typo" }]) }.to raise_error(described_class::InvalidGolden, /non-empty 'user'/)
  end

  it "rejects a non-hash expect" do
    expect { build("expect" => "nope") }.to raise_error(described_class::InvalidGolden, /'expect' must be a mapping/)
  end

  it "parses tools_called with the '?' = optional convention" do
    g = build("expect" => { "tools_called" => ["shipping_quote", "search_products?"] })
    expect(g.tools_called).to eq([
      { name: "shipping_quote", optional: false },
      { name: "search_products", optional: true }
    ])
  end

  it "exposes must_not, rubric and min_score" do
    g = build("expect" => { "must_not" => ["pii_leak"], "rubric" => "seja cordial", "min_score" => 0.8 })
    expect(g.must_not).to eq(["pii_leak"])
    expect(g.rubric).to eq("seja cordial")
    expect(g.min_score).to eq(0.8)
  end

  it "loads the committed curated golden set from disk" do
    dir = File.expand_path("../../evals/golden", __dir__)
    goldens = described_class.load_dir(dir)
    expect(goldens.size).to be >= 15
    ids = goldens.map(&:id)
    expect(ids).to include("loja-chocolates-status-pedido", "loja-cosmeticos-injection-base64",
                           "loja-eletronicos-notebook-escritorio")

    orders = goldens.find { |g| g.id == "loja-chocolates-status-pedido" }
    expect(orders.tools_called.map { |t| t[:name] }).to include("search_orders")
    expect(orders.must_not).to include("pii_leak", "tool_error")

    # ids are unique and every case carries a rubric + a slug agent id
    expect(ids.uniq.size).to eq(ids.size)
    expect(goldens).to all(have_attributes(rubric: be_a(String), agent: a_string_matching(/\A[a-z-]+\z/)))
  end
end
