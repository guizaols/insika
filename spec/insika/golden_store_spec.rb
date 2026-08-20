# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# eval cases move from files-only to a store, so the rubric — the part
# of an eval a domain owner can actually write — is authorable without a checkout. The
# corpus on disk stays the seed and the export format.
RSpec.describe Insika::GoldenStore do
  subject(:store) { described_class.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }

  def a_case(id: "loja-cupom", agent: "loja", rubric: "Consults the coupon by tool and invents nothing.")
    { "id" => id, "agent" => agent,
      "turns" => [{ "user" => "tem cupom?" }],
      "expect" => { "tools_called" => ["search_voucher"], "must_not" => %w[pii_leak],
                    "rubric" => rubric, "min_score" => 0.7 } }
  end

  it "round-trips a case through the store" do
    store.write(a_case)
    golden = store.find("loja-cupom")

    expect(golden.agent).to eq("loja")
    expect(golden.user_turns).to eq(["tem cupom?"])
    expect(golden.tools_called).to eq([{ name: "search_voucher", optional: false }])
    expect(golden.must_not).to eq(%w[pii_leak])
    expect(golden.min_score).to eq(0.7)
  end

  # RFC-0014: a SIMULATED case is one of two shapes — the persona must survive
  # the store AND the YAML export, or it would silently stop being simulated and
  # replay as an empty script.
  it "round-trips a persona case (simulated) through the store and out to YAML" do
    sim = { "id" => "loja-sim", "agent" => "loja",
            "persona" => { "goal" => "find a gift", "knows" => { "budget" => "100" },
                           "opens_with" => "oi", "max_turns" => 6 },
            "expect" => { "rubric" => "Descobre o objetivo antes de recomendar" } }
    store.write(sim)
    golden = store.find("loja-sim")
    expect(golden.simulated?).to be(true)
    expect(golden.persona.max_turns).to eq(6)
    expect(golden.user_turns).to eq([])

    Dir.mktmpdir do |dir|
      store.export_dir(dir)
      exported = Insika::Evals::GoldenLoader.load_dir(dir).first
      expect(exported.simulated?).to be(true)
      expect(exported.persona.knows).to eq("budget" => "100")
    end
  end

  # A case that lost its `requires` on the way through the store would come back as a
  # FAILURE on every deployment lacking the tool — the exact lie the key exists to end.
  it "keeps `requires` across the store and back out to YAML" do
    store.write(a_case.merge("requires" => { "tools" => %w[search_voucher] }))

    expect(store.find("loja-cupom").required_tools).to eq(%w[search_voucher])

    Dir.mktmpdir do |dir|
      store.export_dir(dir)
      exported = Insika::Evals::GoldenLoader.load_dir(dir).first
      expect(exported.required_tools).to eq(%w[search_voucher])
    end
  end

  it "validates on WRITE with the same loader the files use — no second validator" do
    expect { store.write(a_case.merge("turns" => [])) }
      .to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /non-empty array/)
    expect { store.write(a_case.reject { |k, _| k == "agent" }) }
      .to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /'agent' is required/)
    expect(store.ids).to eq([]) # nothing malformed landed
  end

  it "accepts symbol keys (an internal caller) and normalizes them" do
    store.write({ id: "x", agent: "a", turns: [{ user: "hi" }], expect: { rubric: "be kind" } })
    expect(store.find("x").rubric).to eq("be kind")
  end

  it "lists by id, filters by agent, and deletes" do
    store.write(a_case(id: "b-2", agent: "beta"))
    store.write(a_case(id: "a-1", agent: "alpha"))

    expect(store.ids).to eq(%w[a-1 b-2])            # lexicographic = a stable run order
    expect(store.for_agent("alpha").map(&:id)).to eq(%w[a-1])
    expect(store.delete("a-1")).to be(true)
    expect(store.delete("a-1")).to be(false)
  end

  # A Studio edit can break the shape. The run must not silently shrink.
  it "reports a stored case that no longer validates instead of dropping it in silence" do
    store.write(a_case(id: "broken"))
    raw = Insika::ConfigStore.new(store: store.instance_variable_get(:@cs).instance_variable_get(:@store))
    raw.put("goldens", "broken", { "case" => { "id" => "broken", "agent" => "loja", "turns" => "oops" } })

    expect(store.find("broken")).to be_nil
    expect(store.invalid).to eq(%w[broken])
    expect(store.all).to eq([]) # a run sees 0 cases, and `invalid` says why
  end

  describe "the corpus on disk" do
    it "imports every case and keeps the file layout for a faithful export" do
      Dir.mktmpdir do |dir|
        ids = store.import_dir("evals/golden")
        expect(ids.size).to eq(Dir.glob("evals/golden/**/*.yml").size)

        paths = store.export_dir(dir).map { |p| p.delete_prefix("#{dir}/") }
        # Not `<agent>/<id>.yml`: the corpus groups the safety suite by PURPOSE, and an
        # export that scattered those files would not be re-importable as the corpus.
        expect(paths.sort).to eq(Dir.glob("evals/golden/**/*.yml").map { |p| p.delete_prefix("evals/golden/") }.sort)

        reimported = Insika::Evals::GoldenLoader.load_dir(dir).sort_by(&:id)
        original = Insika::Evals::GoldenLoader.load_dir("evals/golden").sort_by(&:id)
        expect(reimported.map { |g| [g.id, g.agent, g.turns, g.expect] })
          .to eq(original.map { |g| [g.id, g.agent, g.turns, g.expect] })
      end
    end

    it "keep_existing leaves an authored case alone (the store wins over the seed)" do
      store.import_dir("evals/golden")
      edited = store.find(store.ids.first).id
      store.write(a_case(id: edited, agent: "loja", rubric: "EDITED"))

      store.import_dir("evals/golden", overwrite: false)
      expect(store.find(edited).rubric).to eq("EDITED")

      store.import_dir("evals/golden") # default overwrites: the seed is the way back
      expect(store.find(edited).rubric).not_to eq("EDITED")
    end

    it "refuses to export over an existing corpus, because YAML.dump drops its comments" do
      store.import_dir("evals/golden")
      expect { store.export_dir("evals/golden") }
        .to raise_error(Insika::ValidationError, /DROPS their comments/)
    end
  end
end
