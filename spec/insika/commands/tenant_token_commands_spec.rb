# frozen_string_literal: true

require "spec_helper"

RSpec.describe "WS1 token commands (issue/revoke/rotate)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:token_store) { Insika::TokenStore.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  let(:bus) do
    Insika::CommandBus.new.tap do |b|
      b.register(:issue_tenant_token,
                 Insika::Commands::IssueTenantToken.new(token_store: token_store, event_stream: event_stream))
      b.register(:revoke_token,
                 Insika::Commands::RevokeToken.new(token_store: token_store, event_stream: event_stream))
      b.register(:rotate_tenant_token,
                 Insika::Commands::RotateTenantToken.new(token_store: token_store, event_stream: event_stream))
    end
  end

  def dispatch(type, payload, tenant: nil)
    bus.dispatch(Insika::Command.build(type, payload, transport: :http, tenant: tenant))
  end

  describe ":issue_tenant_token" do
    it "issues a per-tenant token and returns it exactly once" do
      result = dispatch(:issue_tenant_token, { tenant_id: "loja-42", label: "widget" })

      expect(result[:tenant_id]).to eq("loja-42")
      expect(result[:token].length).to eq(64)
      expect(token_store.resolve(result[:token]).role).to eq("tenant")
    end

    it "requires a tenant_id (an operator token has no reason to be issued via command)" do
      expect { dispatch(:issue_tenant_token, {}) }.to raise_error(Insika::ValidationError, /tenant_id/)
    end

    it "refuses a command stamped with a tenant (a tenant cannot mint credentials)" do
      expect { dispatch(:issue_tenant_token, { tenant_id: "x" }, tenant: "loja-1") }
        .to raise_error(Insika::ValidationError, /operator-only/)
    end
  end

  describe ":revoke_token" do
    it "revokes by id, and the token stops resolving" do
      issued = dispatch(:issue_tenant_token, { tenant_id: "loja-1" })
      result = dispatch(:revoke_token, { token_id: issued[:id] })

      expect(result[:revoked]).to be(true)
      expect(token_store.resolve(issued[:token])).to be_nil
    end

    it "is idempotent: revoking again -> { revoked: false }, not an error" do
      issued = dispatch(:issue_tenant_token, { tenant_id: "loja-1" })
      dispatch(:revoke_token, { token_id: issued[:id] })

      expect(dispatch(:revoke_token, { token_id: issued[:id] })).to eq(id: issued[:id], revoked: false)
    end

    it "requires token_id" do
      expect { dispatch(:revoke_token, {}) }.to raise_error(Insika::ValidationError, /token_id/)
    end

    it "refuses a tenant-stamped command" do
      expect { dispatch(:revoke_token, { token_id: "t" }, tenant: "loja-1") }
        .to raise_error(Insika::ValidationError, /operator-only/)
    end
  end

  describe ":rotate_tenant_token" do
    it "revokes the tenant's old tokens and issues a fresh one" do
      old = dispatch(:issue_tenant_token, { tenant_id: "loja-b" })
      result = dispatch(:rotate_tenant_token, { tenant_id: "loja-b" })

      expect(result[:revoked]).to eq(1)
      expect(token_store.resolve(old[:token])).to be_nil
      expect(token_store.resolve(result[:token][:token])).not_to be_nil
      expect(result[:token][:tenant_id]).to eq("loja-b")
    end

    it "does not touch another tenant's tokens" do
      other = dispatch(:issue_tenant_token, { tenant_id: "loja-a" })
      dispatch(:rotate_tenant_token, { tenant_id: "loja-b" })

      expect(token_store.resolve(other[:token])).not_to be_nil
    end

    it "requires tenant_id and refuses tenant-stamped commands" do
      expect { dispatch(:rotate_tenant_token, {}) }.to raise_error(Insika::ValidationError, /tenant_id/)
      expect { dispatch(:rotate_tenant_token, { tenant_id: "x" }, tenant: "loja-1") }
        .to raise_error(Insika::ValidationError, /operator-only/)
    end
  end

  it "the three commands are registered by the core bus (Wiring::Graph)" do
    spine = Insika::Wiring::Graph.spine(backend: Insika::Stores::Memory.new)
    graph = Insika::Wiring::Graph.build(
      spine: spine, profiles: {}, tool_registry: spine.code_tool_registry,
      tool_catalog: Insika::ToolCatalog.new(tool_registry: spine.code_tool_registry),
      skill_catalog: Insika::SkillCatalog.new([]), prompt_catalog: Insika::PromptCatalog.new([]),
      guardrails: Insika::Safety::Factory.new,
      context_providers: [Insika::Context::Providers::Request.new]
    )

    %i[issue_tenant_token revoke_token rotate_tenant_token].each do |type|
      expect(graph.bus.registered?(type)).to be(true)
    end
  end
end