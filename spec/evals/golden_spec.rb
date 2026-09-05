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
                              "blocked_gates" => ["add_to_cart:provenance"] })
      expect(g.never_calls).to eq(["search_products"])
      expect(g.calls_one_of).to eq(%w[a b])
      expect(g.first_tool).to eq("a")
      expect(g.max_tool_calls).to eq(2)
      expect(g.reply_includes).to eq(["frete"])
      expect(g.reply_omits).to eq(["SKU-1"])
      expect(g.blocked_gates).to eq(["add_to_cart:provenance"])

      bare = build
      expect(bare.never_calls).to eq([])
      expect(bare.first_tool).to be_nil
      expect(bare.max_tool_calls).to be_nil
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
