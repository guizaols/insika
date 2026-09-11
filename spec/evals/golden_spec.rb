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

  # `state:` — the snapshot a case starts from. Only the four known keys, each in
  # its own shape, refused at LOAD: a typo'd key would seed nothing and the case
  # would pass against the wrong precondition.
  describe "state (the snapshot a case starts from)" do
    let(:state) do
      { "evidence" => { "ids" => ["SKU-1"] }, "memory" => { "facts" => { "size" => "38" }, "notes" => ["n"] },
        "history" => [{ "role" => "user", "content" => "oi" }], "briefing" => { "fields" => { "cep" => "01311" } } }
    end

    it "is {} and not seeded? when absent" do
      expect(build.state).to eq({})
      expect(build.seeded?).to be(false)
    end

    it "accepts the four known keys and reads as seeded?" do
      g = build("state" => state)
      expect(g.state).to eq(state)
      expect(g.seeded?).to be(true)
    end

    it "a persona case may carry state too" do
      g = build("turns" => nil, "state" => state,
                "persona" => { "goal" => "g", "knows" => { "k" => "v" }, "max_turns" => 2, "opens_with" => "oi" })
      expect(g.simulated?).to be(true)
      expect(g.seeded?).to be(true)
    end

    it "refuses an unknown key, a non-mapping, and a malformed shape" do
      expect { build("state" => { "evidences" => {} }) }
        .to raise_error(described_class::InvalidGolden, /unknown key\(s\) evidences — known: evidence, memory, history, briefing/)
      expect { build("state" => "nope") }.to raise_error(described_class::InvalidGolden, /state .* must be a mapping/)
      expect { build("state" => { "evidence" => { "ids" => "SKU-1" } }) }
        .to raise_error(described_class::InvalidGolden, /evidence\.ids must be a list/)
      expect { build("state" => { "memory" => { "facts" => ["x"] } }) }
        .to raise_error(described_class::InvalidGolden, /memory\.facts must be a mapping/)
      expect { build("state" => { "history" => [{ "role" => "system", "content" => "x" }] }) }
        .to raise_error(described_class::InvalidGolden, /history must be/)
      expect { build("state" => { "history" => [{ "role" => "user" }] }) }
        .to raise_error(described_class::InvalidGolden, /history must be/)
    end
  end

  describe "the call and reply graders" do
    it "exposes each grader from expect, empty/nil when absent" do
      g = build("expect" => { "never_calls" => ["search_products"], "calls_one_of" => %w[a b], "first_tool" => "a",
                              "max_tool_calls" => 2, "reply_includes" => ["frete"], "reply_omits" => ["SKU-1"],
                              "blocked_gates" => ["add_to_cart:provenance"], "ui_components" => ["product_cards"],
                              "no_ui" => true })
      expect(g.never_calls).to eq(["search_products"])
      expect(g.calls_one_of).to eq(%w[a b])
      expect(g.first_tool).to eq("a")
      expect(g.max_tool_calls).to eq(2)
      expect(g.reply_includes).to eq(["frete"])
      expect(g.reply_omits).to eq(["SKU-1"])
      expect(g.blocked_gates).to eq(["add_to_cart:provenance"])
      expect(g.ui_components).to eq(["product_cards"])
      expect(g.no_ui?).to be(true)

      bare = build
      expect(bare.never_calls).to eq([])
      expect(bare.first_tool).to be_nil
      expect(bare.max_tool_calls).to be_nil
      expect(bare.ui_components).to eq([])
      expect(bare.no_ui?).to be(false)
    end

    it "refuses a max_tool_calls that is not a non-negative integer, and a blocked_gates entry without its gate" do
      expect { build("expect" => { "max_tool_calls" => "two" }) }
        .to raise_error(described_class::InvalidGolden, /max_tool_calls must be a non-negative integer/)
      expect { build("expect" => { "max_tool_calls" => -1 }) }.to raise_error(described_class::InvalidGolden)
      expect { build("expect" => { "blocked_gates" => ["add_to_cart"] }) }
        .to raise_error(described_class::InvalidGolden, /blocked_gates entries are 'tool:gate'/)
    end
  end

  # C3.1: run_persona_eval's isolation check compares this against the calling
  # agent's own tenant — "platform" has to be the default, or every case
  # authored before tenants existed would suddenly belong to nobody.
  it "defaults tenant to 'platform', or keeps an explicit one" do
    expect(build.tenant).to eq("platform")
    expect(build("tenant" => "acme").tenant).to eq("acme")
    expect(build("tenant" => "  ").tenant).to eq("platform") # blank is absent, not a tenant named " "
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


# `store_state:` — what the store must look like after the turn.
RSpec.describe Insika::Evals::GoldenLoader do
  def build(store_state)
    described_class.build({ "id" => "bench-order", "agent" => "bia", "turns" => [{ "user" => "compra" }],
                            "expect" => {}, "store_state" => store_state })
  end

  it "accepts records, count and absent, and names the collections it will read" do
    g = build({ "records" => { "orders" => [{ "total" => 189.9 }] },
                "count" => { "orders" => 1 },
                "absent" => { "carts" => [{ "status" => "open" }] } })
    expect(g.store_state?).to be(true)
    expect(g.store_collections).to contain_exactly("orders", "carts")
  end

  it "a case with no store_state says nothing about the store" do
    g = described_class.build({ "id" => "c", "agent" => "bia", "turns" => [{ "user" => "oi" }], "expect" => {} })
    expect(g.store_state?).to be(false)
    expect(g.store_collections).to be_empty
  end

  # The reason the vocabulary is closed: `orders:` written at the top level would
  # grade nothing and the task would pass on its reply alone.
  it "refuses an unknown key inside store_state" do
    expect { build({ "orders" => [{ "total" => 1 }] }) }
      .to raise_error(described_class::InvalidGolden, /unknown key\(s\) orders/)
  end

  it "refuses a count that is not a non-negative integer, and rows that are not mappings" do
    expect { build({ "count" => { "orders" => "one" } }) }
      .to raise_error(described_class::InvalidGolden, /count.orders must be a non-negative integer/)
    expect { build({ "records" => { "orders" => [] } }) }
      .to raise_error(described_class::InvalidGolden, /records.orders must be a non-empty list/)
  end
end

# A turn that pins its own calls — the shape the bench's mutation tasks use.
RSpec.describe Insika::Evals::GoldenLoader do
  it "keeps a turn's tools_called and reads it back per turn" do
    g = described_class.build({ "id" => "c", "agent" => "bia", "expect" => {},
                              "turns" => [{ "user" => "oi", "tools_called" => ["add_to_cart", "view_cart?"] },
                                          { "user" => "ok" }] })
    expect(g.turn_tools_called(0)).to eq([{ name: "add_to_cart", optional: false }, { name: "view_cart", optional: true }])
    expect(g.turn_tools_called(1)).to eq([])
    expect(g.user_turns).to eq(%w[oi ok])
  end

  it "refuses phantom_action without claims, and a claims pattern that does not compile" do
    base = { "id" => "c", "agent" => "bia", "turns" => [{ "user" => "oi" }] }
    expect { described_class.build(base.merge("expect" => { "must_not" => ["phantom_action"] })) }
      .to raise_error(described_class::InvalidGolden, /needs a non-empty 'claims:'/)
    expect { described_class.build(base.merge("expect" => { "claims" => { "add_to_cart" => "(" } })) }
      .to raise_error(described_class::InvalidGolden, /claims.add_to_cart is not a valid pattern/)
    ok = described_class.build(base.merge("expect" => { "must_not" => ["phantom_action"], "claims" => { "add_to_cart" => "adicionei" } }))
    expect(ok.claims).to eq("add_to_cart" => "adicionei")
  end

  it "rejects a turn's tools_called that is not a list of names" do
    expect do
      described_class.build({ "id" => "c", "agent" => "bia", "expect" => {},
                            "turns" => [{ "user" => "oi", "tools_called" => "add_to_cart" }] })
    end.to raise_error(described_class::InvalidGolden, /tools_called must be a list/)
  end
end
