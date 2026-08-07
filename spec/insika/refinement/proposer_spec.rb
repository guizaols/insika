# frozen_string_literal: true

require "spec_helper"

# RFC-0013 §3.4 (PR 3b) — the one place a model is asked for anything in the whole
# refinement loop. What matters here is what it REFUSES to produce: this class is
# upstream of every bound, so anything it invents silently would reach the gate
# looking like evidence.
RSpec.describe Insika::Refinement::Proposer do
  let(:findings) do
    [{ "kind" => "tool_error", "count" => 24, "title" => "shipping_quote failed",
       "detail" => "cep is required" },
     { "kind" => "repetition", "count" => 7, "title" => "customer repeated themselves" }]
  end
  let(:files) { { "TOOLS.md" => "# Tools\n\nUse shipping_quote to quote freight.\n" } }

  def proposer(reply, model: "deepseek/deepseek-chat", &capture)
    described_class.new(ask: lambda { |prompt|
      capture&.call(prompt)
      reply
    }, model: model)
  end

  def propose(reply, **kw, &capture)
    proposer(reply, **kw, &capture).propose(agent_id: "support", findings: findings, files: files)
  end

  JSON_REPLY = <<~JSON
    {"rationale": "TOOLS.md never says the CEP is required.",
     "edits": [{"file": "TOOLS.md", "op": "replace", "anchor": "## shipping_quote",
                "before": "Use shipping_quote to quote freight.",
                "after": "Use shipping_quote to quote freight. Ask for the CEP first.",
                "addresses": ["tool_error:shipping_quote"]}]}
  JSON

  it "returns the raw candidate, stamped with the model that wrote it" do
    raw = propose(JSON_REPLY)

    expect(raw["proposer"]).to eq("deepseek/deepseek-chat")
    expect(raw["edits"].first["file"]).to eq("TOOLS.md")
    expect(raw["rationale"]).to match(/CEP/)
  end

  # The wrapper every chat model reaches for. Stripping it is not leniency — what is
  # inside is still parsed strictly.
  it "reads a fenced JSON block" do
    expect(propose("```json\n#{JSON_REPLY}\n```")["edits"].size).to eq(1)
  end

  it "reads JSON that arrives with prose around it" do
    expect(propose("Sure! Here you go:\n#{JSON_REPLY}\nHope that helps.")["edits"].size).to eq(1)
  end

  # A model that answers in prose has proposed NOTHING, and it has to say so out
  # loud: an empty candidate returned quietly reads as "the traffic is fine".
  it "refuses an answer with no JSON in it" do
    expect { propose("I think the prompt is fine as it is.") }
      .to raise_error(described_class::Unusable, /no JSON object/)
  end

  it "refuses malformed JSON" do
    expect { propose('{"edits": [}') }
      .to raise_error(described_class::Unusable, /not valid JSON/)
  end

  it "refuses JSON that carries no edits list" do
    expect { propose('{"rationale": "looks fine"}') }
      .to raise_error(described_class::Unusable, /no `edits`/)
  end

  # Asking a model to invent an improvement from no evidence is how a refinement
  # loop starts rewriting a prompt that works.
  it "refuses to propose from a run with no findings" do
    asked = false
    p = described_class.new(ask: ->(_) { asked = true }, model: "m")
    expect { p.propose(agent_id: "support", findings: [], files: files) }
      .to raise_error(described_class::Unusable, /nothing to propose from/)
    expect(asked).to be(false)
  end

  it "refuses when no file is writable, without calling the model" do
    asked = false
    p = described_class.new(ask: ->(_) { asked = true }, model: "m")
    expect { p.propose(agent_id: "support", findings: findings, files: {}) }
      .to raise_error(described_class::Unusable, /no writable file/)
    expect(asked).to be(false)
  end

  describe "the prompt" do
    it "carries the findings with their counts and the file verbatim" do
      seen = nil
      propose(JSON_REPLY) { |prompt| seen = prompt }

      expect(seen).to include("tool_error (×24)", "cep is required", "repetition (×7)")
      expect(seen).to include("### TOOLS.md", "Use shipping_quote to quote freight.")
    end

    # The bounds are enforced downstream either way, but a model told "3 edits" that
    # writes 8 wastes a provider call and shows the operator a candidate that is
    # mostly drops.
    it "states the bounds it will be judged against" do
      seen = nil
      described_class.new(ask: ->(p) { seen = p; JSON_REPLY }, model: "m")
                     .propose(agent_id: "support", findings: findings, files: files,
                              limits: { "max_edits" => 1, "max_bytes" => 400 })

      expect(seen).to include("At most 1 edits", "at most 400 bytes")
    end

    # Measured, not reasoned: shown tool errors that were really a blocked
    # destination, the model proposed telling the agent to "always use https" —
    # advice about something it does not control. Naming the trap removed it.
    it "names infrastructure findings as unfixable by text" do
      seen = nil
      propose(JSON_REPLY) { |prompt| seen = prompt }
      expect(seen).to include("INFRASTRUCTURE", "never say how to call it correctly")
    end

    it "shows only the files it is allowed to edit" do
      seen = nil
      propose(JSON_REPLY) { |prompt| seen = prompt }
      expect(seen).not_to include("AGENTS.md")
    end
  end
end

RSpec.describe Insika::Refinement::ProposerFactory do
  # ask_factory records which model/provider the ref resolved to, so the resolution
  # rule is testable without a provider gem.
  def build(config, utility_model: nil)
    resolved = nil
    proposer = described_class.build(config, utility_model: utility_model,
                                             ask_factory: lambda { |model, provider|
                                               resolved = [model, provider]
                                               ->(_) { "{}" }
                                             })
    [proposer, resolved]
  end

  it "takes the agent's proposer, splitting provider/model" do
    proposer, resolved = build({ "proposer" => "deepseek/deepseek-chat" })
    expect(proposer).to be_a(Insika::Refinement::Proposer)
    expect(resolved).to eq(["deepseek-chat", "deepseek"])
  end

  it "reads a bare model name as having no provider" do
    _, resolved = build({ "proposer" => "gpt-5-mini" })
    expect(resolved).to eq(["gpt-5-mini", nil])
  end

  it "falls back to the platform utility_model" do
    _, resolved = build({ "mode" => "propose" }, utility_model: "deepseek/deepseek-chat")
    expect(resolved).to eq(["deepseek-chat", "deepseek"])
  end

  # No default model, ever: guessing one spends an operator's provider budget
  # without being asked. The caller turns this nil into a refusal.
  it "is nil when nothing is configured" do
    proposer, = build({ "mode" => "propose" })
    expect(proposer).to be_nil
  end
end
