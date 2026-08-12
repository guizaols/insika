# frozen_string_literal: true

require "spec_helper"
require "insika/tools/load_skill" # loaded lazily in production; explicit in the test

RSpec.describe Insika::Tools::LoadSkill do
  # Catalog double with the surface used (find -> Skill|nil).
  Skill = Struct.new(:name, :body, :companions)

  let(:catalog) do
    instance_double("Insika::SkillCatalog").tap do |c|
      allow(c).to receive(:find) { |name| name == "cardapio" ? Skill.new("cardapio", "CORPO") : nil }
    end
  end

  it "returns the skill body when allowed and present" do
    tool = described_class.new(catalog, ["cardapio"])

    expect(tool.execute(name: "cardapio")).to eq("CORPO")
  end

  it "refuses a skill outside the allowlist (without raising)" do
    tool = described_class.new(catalog, ["pedido"])

    expect(tool.execute(name: "cardapio")).to eq({ error: "skill 'cardapio' not available for this agent" })
  end

  it "reports a skill that is allowed but nonexistent in the catalog" do
    tool = described_class.new(catalog, ["fantasma"])

    expect(tool.execute(name: "fantasma")).to eq({ error: "skill 'fantasma' not found" })
  end

  # `agent` decides WHICH body a name resolves to: an agent that specialized a shared
  # skill must be served its own version, under the same bare name — otherwise the
  # override is invisible on the one path the model actually uses.
  describe "the agent scope" do
    let(:scoped) do
      instance_double("Insika::SkillCatalog").tap do |c|
        allow(c).to receive(:find).with("esc", agent: nil).and_return(Skill.new("esc", "SHARED"))
        allow(c).to receive(:find).with("esc", agent: "cacau").and_return(Skill.new("esc", "MINE"))
      end
    end

    it "serves the agent's own body" do
      expect(described_class.new(scoped, ["esc"], agent: "cacau").execute(name: "esc")).to eq("MINE")
    end

    it "no agent -> the shared body (parity)" do
      expect(described_class.new(scoped, ["esc"]).execute(name: "esc")).to eq("SHARED")
    end
  end

  # Half a recipe is worse than none: the model that holds a reference table without
  # the procedure that reads it never asks for the other half. Declared companions come
  # back in the SAME call.
  describe "companions" do
    let(:paired) do
      instance_double("Insika::SkillCatalog").tap do |c|
        allow(c).to receive(:find) do |name, **|
          { "mapa" => Skill.new("mapa", "MAP", ["query"]),
            "query" => Skill.new("query", "RULES", []),
            "eager-one" => Skill.new("eager-one", "E", []) }[name.to_s]
        end
      end
    end

    it "returns the skill and its companion in one call" do
      out = described_class.new(paired, %w[mapa query]).execute(name: "mapa")

      expect(out).to include('<skill name="mapa">', "MAP", '<skill name="query">', "RULES")
    end

    it "a skill with no companions returns its BARE body, byte for byte (parity)" do
      expect(described_class.new(paired, %w[mapa query]).execute(name: "query")).to eq("RULES")
    end

    # @allowed is the LAZY set, so a companion that is eager is already in the prompt in
    # full — fetching it again would only buy a duplicate.
    it "skips a companion that is not in the served set" do
      expect(described_class.new(paired, ["mapa"]).execute(name: "mapa")).to eq("MAP")
    end
  end

  # This tool is NOT enveloped, and the envelope is what writes the tool trace —
  # so activation was the one call missing from the Studio's trace.
  describe "trace (it is not enveloped, so it records itself)" do
    let(:recorder) { [] }
    let(:trace_recorder) do
      Class.new do
        def initialize(sink) = @sink = sink
        def record(session_id:, entry:) = @sink << { session_id: session_id, entry: entry }
      end.new(recorder)
    end
    let(:state) do
      task = Struct.new(:id, :session_id).new("t1", "s1")
      Struct.new(:task, :turn).new(task, 3)
    end

    it "records the activation keyed by session, in the envelope's shape" do
      tool = described_class.new(catalog, ["cardapio"], trace_recorder: trace_recorder, state: state)

      expect(tool.execute(name: "cardapio")).to eq("CORPO")

      expect(recorder.length).to eq(1)
      expect(recorder.first[:session_id]).to eq("s1")
      entry = recorder.first[:entry]
      expect(entry["tool"]).to eq("load_skill")
      expect(entry["turn"]).to eq(3)
      expect(entry["args"]).to eq({ "name" => "cardapio" })
      expect(entry["result"]).to eq("CORPO")
      expect(entry["ms"]).to be_a(Integer)
    end

    it "records a refusal too — the result carries the error the store reads as not-ok" do
      tool = described_class.new(catalog, ["pedido"], trace_recorder: trace_recorder, state: state)

      tool.execute(name: "cardapio")

      expect(recorder.first[:entry]["result"]).to eq({ error: "skill 'cardapio' not available for this agent" })
    end

    it "no recorder -> no trace, and the body still returns (parity)" do
      tool = described_class.new(catalog, ["cardapio"])

      expect(tool.execute(name: "cardapio")).to eq("CORPO")
      expect(recorder).to be_empty
    end

    it "a session-less state does not trace and never breaks the call" do
      task = Struct.new(:id, :session_id).new("t1", nil)
      stateless = Struct.new(:task, :turn).new(task, 1)
      tool = described_class.new(catalog, ["cardapio"], trace_recorder: trace_recorder, state: stateless)

      expect(tool.execute(name: "cardapio")).to eq("CORPO")
      expect(recorder).to be_empty
    end

    it "a recorder that raises never breaks the turn" do
      exploding = Class.new { def record(session_id:, entry:) = raise("trace down") }.new
      tool = described_class.new(catalog, ["cardapio"], trace_recorder: exploding, state: state)

      expect(tool.execute(name: "cardapio")).to eq("CORPO")
    end
  end
end
