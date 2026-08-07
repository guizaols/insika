# frozen_string_literal: true

require "spec_helper"

# RFC-0013 §3.4 — the candidate format is the trust boundary made checkable. Every
# case here is one way a proposal could quietly damage an agent's prompt, and the
# assertion is that it is dropped WITH a reason instead.
RSpec.describe Insika::Refinement::CandidateBuilder do
  # Sized like a real prompt file on purpose. `max_total_growth` is RELATIVE (15% of
  # the file), so a toy three-line fixture would reject edits a real agent accepts —
  # and the first draft of this spec failed for exactly that reason, which is the
  # honest way to learn that a near-empty file is effectively not refinable.
  TOOLS_MD = <<~MD + ("Answer in the customer's language, briefly and warmly.\n" * 12)
    # Tools

    ## shipping_quote
    Use shipping_quote to quote freight.

    ## order_status
    Use order_status to look an order up.

  MD

  IDENTITY_MD = "You are Bia.\n" + ("You work for an online shop and you are never pushy.\n" * 10)

  let(:contents) { { "TOOLS.md" => TOOLS_MD, "IDENTITY.md" => IDENTITY_MD } }
  let(:allowlist) { %w[TOOLS.md IDENTITY.md] }

  def edit(**over)
    { "file" => "TOOLS.md", "op" => "replace",
      "anchor" => "## shipping_quote",
      "before" => "Use shipping_quote to quote freight.",
      "after" => "Use shipping_quote to quote freight. Always ask for the CEP first.",
      "addresses" => ["tool_error:shipping_quote"] }.merge(over.transform_keys(&:to_s))
  end

  def build(edits, allow: allowlist, limits: {}, files: contents)
    described_class.build({ "proposer" => "m", "rationale" => "r", "edits" => Array(edits) },
                          allowlist: allow, contents: files, limits: limits)
  end

  def reasons(candidate) = candidate.dropped.map(&:reason)

  it "keeps a well-formed anchored edit and applies it in place" do
    candidate = build([edit])
    expect(candidate.edits.size).to eq(1)
    expect(candidate.dropped).to be_empty

    applied = candidate.apply(contents)
    expect(applied.keys).to eq(["TOOLS.md"])
    expect(applied["TOOLS.md"]).to include("Always ask for the CEP first.")
    expect(applied["TOOLS.md"]).to include("## order_status") # the rest of the file survives
  end

  it "carries the proposer, rationale and what each edit claims to address" do
    candidate = build([edit])
    expect(candidate.proposer).to eq("m")
    expect(candidate.rationale).to eq("r")
    expect(candidate.edits.first.addresses).to eq(["tool_error:shipping_quote"])
  end

  # §3.1: the allowlist is the write surface, and an EMPTY one means report-only —
  # not "unrestricted". A missing config must never be the most permissive setting.
  describe "the write allowlist" do
    it "drops a file nobody allowlisted" do
      candidate = build([edit(file: "GUARDRAILS.md")], allow: %w[TOOLS.md])
      expect(candidate).to be_empty
      expect(reasons(candidate).first).to match(/not on the refinement allowlist/)
    end

    it "drops everything when the allowlist is empty" do
      expect(build([edit], allow: [])).to be_empty
    end
  end

  # The stale check is the reason the format is anchored at all: a proposal built
  # from a snapshot must not clobber an edit made since.
  describe "staleness" do
    it "drops a replace whose `before` is no longer in the file" do
      candidate = build([edit(before: "Use shipping_quote to quote shipping.")])
      expect(candidate).to be_empty
      expect(reasons(candidate).first).to match(/no longer matches.*stale or invented/)
    end

    it "drops an ambiguous `before` rather than picking an occurrence" do
      repeated = { "TOOLS.md" => "Ask for the CEP.\n\nAsk for the CEP.\n" }
      candidate = build([edit(before: "Ask for the CEP.", after: "Ask for the CEP and the number.")],
                        files: repeated)
      expect(candidate).to be_empty
      expect(reasons(candidate).first).to match(/2 places — ambiguous/)
    end

    it "drops a replace with an empty `before` — that is a rewrite, not an edit" do
      expect(reasons(build([edit(before: "")])).first).to match(/a replace with no anchor text is a rewrite/)
    end

    it "drops an edit to a file the agent does not have" do
      expect(reasons(build([edit(file: "IDENTITY.md", before: "nope")])).first)
        .to match(/no longer matches/)
      expect(reasons(build([edit(file: "MISSING.md")], allow: %w[MISSING.md])).first)
        .to match(/does not exist for this agent/)
    end
  end

  describe "bounds" do
    it "drops an edit over max_bytes" do
      candidate = build([edit(after: "x" * 200)], limits: { "max_bytes" => 100 })
      expect(reasons(candidate).first).to match(/over max_bytes/)
    end

    it "keeps only max_edits and says the rest were over the cap" do
      three = [edit,
               edit(before: "Use order_status to look an order up.", after: "Use order_status always."),
               edit(file: "IDENTITY.md", before: "You are Bia.", after: "You are Bia, of Acme.")]
      candidate = build(three, limits: { "max_edits" => 2 })
      expect(candidate.edits.size).to eq(2)
      expect(reasons(candidate).first).to match(/over max_edits/)
    end

    # Per FILE and across the whole candidate: three edits each under the byte cap
    # must not add up to a rewritten file.
    it "caps total growth per file, counting every edit to it" do
      grow = ->(n) { edit(op: "append", before: "", after: "y" * n) }
      candidate = build([grow.call(20), grow.call(20), grow.call(20)],
                        limits: { "max_total_growth" => 0.05, "max_edits" => 5 })
      expect(candidate.edits.size).to be < 3
      expect(reasons(candidate).last).to match(/over max_total_growth/)
    end

    it "measures growth against a replace's net change, not its whole size" do
      # A replace that swaps 37B for 40B grows the file by 3B, not by 40B.
      candidate = build([edit(after: "Use shipping_quote to quote freight!!!")],
                        limits: { "max_total_growth" => 0.01 })
      expect(candidate.edits.size).to eq(1)
    end
  end

  describe "op" do
    it "appends at the end of the file, leaving the rest untouched" do
      candidate = build([edit(op: "append", before: "", after: "## refunds\nRefunds take 5 days.")])
      applied = candidate.apply(contents)
      expect(applied["TOOLS.md"]).to start_with("# Tools")
      expect(applied["TOOLS.md"]).to end_with("## refunds\nRefunds take 5 days.\n")
    end

    it "refuses an op it does not know rather than guessing one" do
      expect(reasons(build([edit(op: "rewrite")])).first).to match(/unknown op 'rewrite'/)
    end

    it "drops an empty `after`" do
      expect(reasons(build([edit(after: "   ")])).first).to match(/'after' is empty/)
    end
  end

  it "composes two edits to the same file in order" do
    two = [edit,
           edit(before: "Use order_status to look an order up.", after: "Use order_status first.")]
    applied = build(two).apply(contents)
    expect(applied["TOOLS.md"]).to include("Always ask for the CEP first.")
    expect(applied["TOOLS.md"]).to include("Use order_status first.")
  end

  # A proposal with two good edits and one stale one is still worth gating; the
  # operator sees the third fell off and why.
  it "keeps the good edits of a partly-bad candidate" do
    candidate = build([edit, edit(before: "gone")])
    expect(candidate.edits.size).to eq(1)
    expect(candidate.dropped.size).to eq(1)
    expect(candidate.dropped.first.file).to eq("TOOLS.md")
  end

  it "tolerates junk without raising — a malformed proposal is empty, not an exception" do
    expect(described_class.build("nope", allowlist: allowlist, contents: contents)).to be_empty
    expect(build([{ "file" => nil }])).to be_empty
    expect(build([])).to be_empty
  end
end
