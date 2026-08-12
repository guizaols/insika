# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/insika/server/tenant_auth"

RSpec.describe Insika::Server::TenantAuth do
  def bearer(token) = "Bearer #{token}"

  describe "single_tenant (no store)" do
    it "resolves the configured gateway token to an operator principal" do
      expect(described_class.check("sekret", nil, bearer("sekret")))
        .to eq(role: "operator", tenant_id: nil)
    end

    it ":disabled when no token is configured — whatever the header says" do
      expect(described_class.check(nil, nil, bearer("x"))).to eq(:disabled)
      expect(described_class.check("", nil, bearer("x"))).to eq(:disabled)
      expect(described_class.check(nil, nil, nil)).to eq(:disabled)
    end

    it ":unauthorized for a wrong token or a missing Bearer" do
      expect(described_class.check("sekret", nil, bearer("wrong"))).to eq(:unauthorized)
      expect(described_class.check("sekret", nil, nil)).to eq(:unauthorized)
      expect(described_class.check("sekret", nil, "Basic dXNlcg==")).to eq(:unauthorized)
    end
  end

  describe "multi_tenant (store present)" do
    let(:backend) { Insika::Stores::Memory.new }
    let(:store) { Insika::TokenStore.new(store: backend) }

    it "a tenant token resolves to its tenant principal" do
      issue = store.issue(tenant_id: "loja-1")
      expect(described_class.check(nil, store, bearer(issue.token)))
        .to eq(role: "tenant", tenant_id: "loja-1")
    end

    it "an operator token in the store resolves as operator" do
      issue = store.issue
      expect(described_class.check(nil, store, bearer(issue.token)))
        .to eq(role: "operator", tenant_id: nil)
    end

    it "the legacy gateway token STILL resolves as operator (mode-switch compat)" do
      expect(described_class.check("legacy", store, bearer("legacy")))
        .to eq(role: "operator", tenant_id: nil)
    end

    it "a revoked token is :unauthorized (indistinguishable from missing)" do
      issue = store.issue(tenant_id: "loja-1")
      store.revoke(issue.id)
      expect(described_class.check(nil, store, bearer(issue.token))).to eq(:unauthorized)
    end

    it "revoking tenant A's token does not affect tenant B's resolution" do
      a = store.issue(tenant_id: "loja-a")
      b = store.issue(tenant_id: "loja-b")
      store.revoke(a.id)

      expect(described_class.check(nil, store, bearer(a.token))).to eq(:unauthorized)
      expect(described_class.check(nil, store, bearer(b.token)))
        .to eq(role: "tenant", tenant_id: "loja-b")
    end

    it "an unknown/empty token is :unauthorized; the store means the gateway is ON" do
      expect(described_class.check(nil, store, bearer("nope"))).to eq(:unauthorized)
      expect(described_class.check(nil, store, nil)).to eq(:unauthorized)
    end
  end
end