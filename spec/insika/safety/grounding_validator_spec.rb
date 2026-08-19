# frozen_string_literal: true

require "spec_helper"

#   (E2's engine half)— the :flag grounding validator. A reply
# claiming a product whose reference is not in the evidence ledger is FLAGGED
# (audit via guardrail_flags -> :guardrail_flagged); a grounded one is not.
RSpec.describe Insika::Safety::GroundingValidator do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:ledger) { Insika::EvidenceLedger.new(store: session_store, session_id: "s1") }

  before { session_store.create(id: "s1") }

  def profile(grounding)
    Insika::AgentProfile.build(id: "store", model: "m", grounding: grounding)
  end

  def state(content, grounding: { "mode" => "flag", "matcher" => { "sku" => '\b[A-Z]{2,4}\d{4,8}\b' } },
            with_ledger: true)
    prof = profile(grounding)
    st = Insika::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
    st.response_content = content
    st.evidence_ledger = ledger if with_ledger
    st
  end

  it "a reply naming a ledgered SKU -> no flags, ungrounded stays 0" do
    ledger.record(%w[TNSR1234])
    st = state("Este é o TNSR1234 que você pediu.")

    described_class.new.call(st)

    expect(st.guardrail_flags).to be_nil
    expect(ledger.ungrounded).to eq(0)
  end

  it "a reply naming an absent SKU -> :ungrounded flag + counter incremented" do
    ledger.record(%w[TNSR1234])
    st = state("O modelo TNSR9999 está disponível.")

    described_class.new.call(st)

    expect(st.guardrail_flags.size).to eq(1)
    expect(st.guardrail_flags.first).to include(category: "ungrounded", source: "evidence")
    expect(st.guardrail_flags.first[:detail]).to include("TNSR9999")
    expect(ledger.ungrounded).to eq(1)
  end

  it "a reply naming NO SKU-shaped token -> no flags (grounding is SKU-only)" do
    ledger.record(%w[TNSR1234])
    st = state("Aqui está o Tênis Runner 42 para você.")

    described_class.new.call(st)

    expect(st.guardrail_flags).to be_nil
    expect(ledger.ungrounded).to eq(0)
  end

  it "the validator never consults guardrails config — grounding is independent of it (D9)" do
    ledger.record(%w[TNSR1234])
    st = state("O modelo TNSR9999 está disponível.")

    described_class.new.call(st)

    # no guardrails on the profile, but the grounding flag still fires.
    expect(st.guardrail_flags.size).to eq(1)
  end

  it "no profile grounding -> no-op" do
    st = Insika::TurnState.new(task: nil, profile: profile(nil), turn: 1, message: "oi")
    st.response_content = "O modelo TNSR9999 existe."
    st.evidence_ledger = ledger

    described_class.new.call(st)

    expect(st.guardrail_flags).to be_nil
  end

  it "state without a ledger -> no-op (duck-typed)" do
    st = state("O modelo TNSR9999 existe.", with_ledger: false)
    described_class.new.call(st)
    expect(st.guardrail_flags).to be_nil
  end

  it ":enforce mode -> the validator is inert (the enforcer owns the cut)" do
    st = state("O modelo TNSR9999 existe.",
               grounding: { "mode" => "enforce", "matcher" => { "sku" => "\\d+" } })
    described_class.new.call(st)
    expect(st.guardrail_flags).to be_nil
  end

  it "an exception inside is swallowed (fail-open: grounding never breaks the turn)" do
    broken = Object.new
    def broken.lines = raise("boom")
    def broken.ids = raise("boom")
    st = state("O modelo TNSR9999 existe.")
    st.evidence_ledger = broken

    expect { described_class.new.call(st) }.not_to raise_error
  end
end
