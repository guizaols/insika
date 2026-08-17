# frozen_string_literal: true

require "spec_helper"

# RFC-0034 C6: the human's answer — approve (→ the RFC-0031 store, CAS,
# provenance `distilled:<session_ref>`), reject (with an optional reason),
# dismiss (latches the tuple). Approval never silently overwrites an operator
# edit (E3 — the CAS + re-present).
RSpec.describe Insika::Commands::ResolveProposal do
  subject(:handler) { described_class.new(proposal_store: proposals, memory_store: memory,
                                          event_stream: stream) }

  let(:backend) { Insika::Stores::Memory.new }
  let(:proposals) { Insika::ProposalStore.new(store: backend) }
  let(:memory) { Insika::MemoryStore.new(store: backend) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(payload, meta: {})
    base = Insika::Command.build(:resolve_proposal, payload)
    meta.empty? ? base : base.with(meta: meta)
  end

  def proposal(key: "size", value: "M", expected_existed: false, expected_revision: nil)
    proposals.create(tenant: "acme", customer: "c-1", session_ref: "acme:sess_1",
                     key: key, value: value, confidence: 0.9,
                     expected_existed: expected_existed, expected_revision: expected_revision)
  end

  def fact(key = "size")
    memory.get_fact(tenant: "acme", customer: "c-1", key: key)
  end

  describe "approve over a NEW fact (E3's second half)" do
    it "writes the fact with origin distilled:<session_ref> and resolves :approved" do
      p = proposal
      resolved = handler.call(cmd({ "proposal_id" => p.id, "decision" => "approved",
                                    "operator" => "studio" }))
      expect(resolved.status).to eq("approved")
      f = fact
      expect(f.value).to eq("M")
      expect(f.origin).to eq("distilled:acme:sess_1")
      expect(events.last.type).to eq(:proposal_approved)
      # the event carries ids and statuses, never values (D7)
      expect(events.last.data).to eq(proposal_id: p.id, status: "approved", operator: "studio")
    end

    it "a fact appearing before approve (the operator created it) -> :stale, the fact stands" do
      p = proposal
      memory.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "L", origin: "operator")
      resolved = handler.call(cmd({ "proposal_id" => p.id, "decision" => "approved" }))
      expect(resolved.status).to eq("stale")
      expect(resolved.current_value).to eq("L")
      expect(fact.value).to eq("L") # the operator's edit wins
      expect(events.last.type).to eq(:proposal_stale)
      expect(events.last.data).to eq(proposal_id: p.id, status: "stale", operator: "operator")
    end
  end

  describe "approve over an EXISTING fact (the CAS, E3)" do
    it "at the right revision -> the fact is replaced, origin distilled, :approved" do
      memory.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "L", origin: "operator")
      revision = fact.updated_at
      p = proposal(expected_existed: true, expected_revision: revision)

      resolved = handler.call(cmd({ "proposal_id" => p.id, "decision" => "approved" }))
      expect(resolved.status).to eq("approved")
      f = fact
      expect(f.value).to eq("M")
      expect(f.origin).to eq("distilled:acme:sess_1")
    end

    it "E3 — the fact moved between distill and approve (an operator put): :stale, NO overwrite" do
      memory.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "L", origin: "operator")
      p = proposal(expected_existed: true, expected_revision: fact.updated_at)
      # the operator edits the fact again AFTER distill
      memory.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "XL", origin: "operator")

      resolved = handler.call(cmd({ "proposal_id" => p.id, "decision" => "approved" }))
      expect(resolved.status).to eq("stale")
      expect(fact.value).to eq("XL") # unchanged — the CAS refused the overwrite
      expect(resolved.current_value).to eq("XL")
      expect(resolved.value).to eq("M") # both values visible through the record (E3)
      expect(events.last.type).to eq(:proposal_stale)
    end
  end

  describe "reject and dismiss" do
    it "reject records the note" do
      p = proposal
      resolved = handler.call(cmd({ "proposal_id" => p.id, "decision" => "rejected",
                                    "note" => "not durable", "operator" => "studio" }))
      expect(resolved.status).to eq("rejected")
      expect(resolved.note).to eq("not durable")
      expect(events.last.type).to eq(:proposal_rejected)
      expect(memory.facts(tenant: "acme", customer: "c-1")).to be_empty
    end

    it "dismiss latches the tuple — a later distillation of the tuple is suppressed" do
      p = proposal
      handler.call(cmd({ "proposal_id" => p.id, "decision" => "dismissed" }))
      expect(proposals.decided?(tenant: "acme", customer: "c-1", key: "size", value: "M")).to be(true)
      expect(events.last.type).to eq(:proposal_dismissed)
    end
  end

  # Blocker 1 — a single-tenant proposal (tenant nil) approves against the
  # BARE customer cell — the cell the provider injects — and the CAS baseline
  # resolves against it.
  describe "single-tenant (tenant nil — the bare customer cell)" do
    def single_proposal(**kw)
      proposals.create(tenant: nil, customer: "c-1", session_ref: "sess_1",
                       key: "size", value: "M", **kw)
    end

    it "approve over a NEW fact writes to memory:<customer>" do
      p = single_proposal
      resolved = handler.call(cmd({ "proposal_id" => p.id, "decision" => "approved" }))
      expect(resolved.status).to eq("approved")
      f = memory.get_fact(tenant: nil, customer: "c-1", key: "size")
      expect(f.value).to eq("M")
      expect(f.origin).to eq("distilled:sess_1")
      expect(memory.get_fact(tenant: "platform", customer: "c-1", key: "size")).to be_nil
    end

    it "the CAS resolves against the bare cell (revision matches -> replaced, never stale)" do
      memory.put_fact(tenant: nil, customer: "c-1", key: "size", value: "L", origin: "operator")
      revision = memory.get_fact(tenant: nil, customer: "c-1", key: "size").updated_at
      p = single_proposal(expected_existed: true, expected_revision: revision)

      resolved = handler.call(cmd({ "proposal_id" => p.id, "decision" => "approved" }))
      expect(resolved.status).to eq("approved")
      expect(memory.get_fact(tenant: nil, customer: "c-1", key: "size").value).to eq("M")
    end
  end

  describe "errors" do
    it "missing proposal_id -> ValidationError" do
      expect { handler.call(cmd({ "decision" => "approved" })) }
        .to raise_error(Insika::ValidationError, /proposal_id/)
    end

    it "an unknown decision -> ValidationError" do
      p = proposal
      expect { handler.call(cmd({ "proposal_id" => p.id, "decision" => "maybe" })) }
        .to raise_error(Insika::ValidationError, /decision/)
    end

    it "double-approve -> the store's loud ArgumentError (a bug, not a retry)" do
      p = proposal
      handler.call(cmd({ "proposal_id" => p.id, "decision" => "approved" }))
      expect { handler.call(cmd({ "proposal_id" => p.id, "decision" => "approved" })) }
        .to raise_error(ArgumentError, /pending/)
      # only ONE fact write happened
      expect(events.count { |e| e.type == :proposal_approved }).to eq(1)
    end

    it "operator defaults from the payload, then command meta, then 'operator'" do
      p = proposal
      handler.call(cmd({ "proposal_id" => p.id, "decision" => "dismissed" },
                       meta: { operator: "console" }))
      expect(events.last.data[:operator]).to eq("console")
    end
  end
end