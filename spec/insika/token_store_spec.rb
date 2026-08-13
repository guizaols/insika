# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::TokenStore do
  subject(:store) { described_class.new(store: backend) }

  let(:backend) { Insika::Stores::Memory.new }

  it "issues a per-tenant token and resolves it back to the principal record" do
    issue = store.issue(tenant_id: "loja-42", label: "widget")

    expect(issue).to be_a(described_class::Issue)
    expect(issue.token.length).to eq(64) # 32 random bytes, hex
    record = store.resolve(issue.token)
    expect(record.role).to eq("tenant")
    expect(record.tenant_id).to eq("loja-42")
    expect(record.label).to eq("widget")
    expect(record.active?).to be(true)
  end

  it "a nil-tenant token resolves as OPERATOR" do
    issue = store.issue(label: "ops")
    record = store.resolve(issue.token)

    expect(record.role).to eq("operator")
    expect(record.tenant_id).to be_nil
  end

  it "never stores the plaintext (only a SHA-256 hash)" do
    issue = store.issue(tenant_id: "t")
    raw = backend.list(described_class::SCOPE).filter_map { |k| backend.get(described_class::SCOPE, k) }
    joined = raw.flatten.join

    expect(joined).not_to include(issue.token)
    expect(issue.token).not_to eq(joined)
  end

  it "resolve returns nil for a missing token and for empty input" do
    expect(store.resolve("nope")).to be_nil
    expect(store.resolve("")).to be_nil
    expect(store.resolve(nil)).to be_nil
  end

  it "revoked tokens stop resolving immediately; revoke is idempotent" do
    issue = store.issue(tenant_id: "t")
    expect(store.resolve(issue.token)).not_to be_nil

    expect(store.revoke(issue.id)).to be(true)
    expect(store.resolve(issue.token)).to be_nil
    expect(store.revoke(issue.id)).to be(false) # already revoked: a no-op, not an error
    expect(store.revoke("ghost")).to be(false)
  end

  it "resolve reads WHO a revoked token was (find), but not as credentials" do
    issue = store.issue(tenant_id: "t")
    store.revoke(issue.id)

    record = store.find(issue.id)
    expect(record.status).to eq("revoked")
    expect(record.tenant_id).to eq("t")
  end

  it "revoke_all touches ONLY the named tenant — other tenants and the operator survive" do
    a = store.issue(tenant_id: "loja-a")
    b = store.issue(tenant_id: "loja-b")
    ops = store.issue

    expect(store.revoke_all(tenant_id: "loja-a")).to eq(1)
    expect(store.resolve(a.token)).to be_nil      # revoked
    expect(store.resolve(b.token)).not_to be_nil  # other tenant untouched
    expect(store.resolve(ops.token)).not_to be_nil # operator untouched
  end

  it "rotate revokes the tenant's tokens and issues a fresh one in ONE atomic call" do
    old = store.issue(tenant_id: "loja-b")
    other = store.issue(tenant_id: "loja-a")

    result = store.rotate(tenant_id: "loja-b", label: "fresh")

    expect(result[:revoked]).to eq(1)
    expect(store.resolve(old.token)).to be_nil
    expect(store.resolve(result[:issue].token)).not_to be_nil
    expect(store.resolve(result[:issue].token).label).to eq("fresh")
    expect(store.resolve(other.token)).not_to be_nil # other tenant survived the rotation
  end

  it "works identically on the SQLite backend (the durable production path)" do
    sqlite = Insika::Stores::SQLite.new(path: ":memory:")
    durable = described_class.new(store: sqlite)
    issue = durable.issue(tenant_id: "t")
    expect(durable.resolve(issue.token).tenant_id).to eq("t")
    durable.revoke(issue.id)
    expect(durable.resolve(issue.token)).to be_nil
    # the no-op revoke (already revoked) must not leak an open transaction:
    # a non-local `return false` inside the block would skip COMMIT and the
    # next transaction would die on "cannot start a transaction within a
    # transaction" (the budget-ledger trap, WS2).
    expect(durable.revoke(issue.id)).to be(false)
    expect(durable.issue(tenant_id: "t").token.length).to eq(64)
  ensure
    sqlite&.close
  end

  it "refuses a tenant_id containing ':' — it IS the session namespace delimiter (WS1)" do
    # T1="loja" + session id "adma:x" lands on "loja:adma:x", the exact cell
    # T2="loja:adma" would claim with id "x": two tenants, one session.
    expect { store.issue(tenant_id: "loja:adma") }.to raise_error(Insika::ValidationError, /must not contain ':'/)
    expect { store.issue(tenant_id: "") }.to raise_error(Insika::ValidationError, /required/)
    # the operator path (nil tenant) is untouched
    expect(store.issue).to be_a(described_class::Issue)
  end
end