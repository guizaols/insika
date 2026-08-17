# frozen_string_literal: true

require "spec_helper"

# RFC-0029 C7/D6 — the :enforce half. The sentence containing an ungrounded
# claim is CUT from the content the turn persists/delivers; the flag carries
# `action: "cut"` and the ledger counter increments.
RSpec.describe Insika::Safety::GroundingEnforcer do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:ledger) { Insika::EvidenceLedger.new(store: session_store, session_id: "s1") }

  before { session_store.create(id: "s1") }

  def profile(grounding)
    Insika::AgentProfile.build(id: "store", model: "m", grounding: grounding)
  end

  def state(content, grounding: { "mode" => "enforce", "matcher" => { "sku" => '\b[A-Z]{2,4}\d{4,8}\b' } })
    prof = profile(grounding)
    st = Insika::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
    st.response_content = content
    st.evidence_ledger = ledger
    st
  end

  def call(content, grounding: { "mode" => "enforce", "matcher" => { "sku" => '\b[A-Z]{2,4}\d{4,8}\b' } })
    described_class.new.call(nil, state(content, grounding: grounding), content)
  end

  it "cuts the sentence with an absent SKU; the rest survives; flag carries action: cut" do
    ledger.record(%w[TNSR1234])
    content, st = call("O TNSR1234 chegou hoje. O TNSR9999 também está em estoque. Obrigado!")

    expect(content).to eq("O TNSR1234 chegou hoje. Obrigado!")
    expect(st.guardrail_flags.first).to include(category: "ungrounded", source: "evidence", action: "cut")
    expect(st.guardrail_flags.first[:detail]).to include("TNSR9999")
    expect(ledger.ungrounded).to eq(1)
  end

  it "flag/off mode -> content untouched" do
    content, = call("O TNSR9999 existe.",
                    grounding: { "mode" => "flag", "matcher" => { "sku" => "\\d+" } })
    expect(content).to eq("O TNSR9999 existe.")

    content, = call("O TNSR9999 existe.",
                    grounding: { "mode" => "off", "matcher" => { "sku" => "\\d+" } })
    expect(content).to eq("O TNSR9999 existe.")
  end

  it "no profile grounding -> content untouched" do
    content, = described_class.new.call(nil, state("x", grounding: nil), "x")
    expect(content).to eq("x")
  end

  it "empty ledger -> every claim is cut (the conservative reading: nothing in the ledger means nothing is grounded)" do
    content, st = call("O TNSR1111 é ótimo. Obrigado!")

    expect(content).to eq("Obrigado!")
    expect(st.guardrail_flags.first[:action]).to eq("cut")
  end

  it "cut boundary: a sentence with TWO claims, one grounded and one not -> the WHOLE sentence is cut (documented conservative behavior)" do
    ledger.record(%w[TNSR1234])
    content, = call("O TNSR1234 e o TNSR9999 estão aqui.")

    expect(content).to eq("")
  end

  it "a grounded-only reply is not cut" do
    ledger.record(%w[TNSR1234])
    content, st = call("O TNSR1234 chegou hoje.")

    expect(content).to eq("O TNSR1234 chegou hoje.")
    expect(st.guardrail_flags).to be_nil
  end

  it "an exception inside is swallowed (fail-open: grounding never breaks a completed turn)" do
    broken = Object.new
    def broken.lines = raise("boom")
    def broken.ids = raise("boom")
    st = state("O TNSR9999 existe.")
    st.evidence_ledger = broken

    content, = described_class.new.call(nil, st, "O TNSR9999 existe.")
    expect(content).to eq("O TNSR9999 existe.")
  end
end
