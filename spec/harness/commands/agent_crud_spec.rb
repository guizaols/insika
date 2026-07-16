# frozen_string_literal: true

require "spec_helper"

# Fase 4 Etapa B: CRUD de agente em runtime (o "cada um cria sua BIA").
RSpec.describe "Commands de autoria de agente (Fase 4 Etapa B)" do
  let(:source) { Harness::StoredProfileSource.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload) = Harness::Command.build(type, payload)

  describe Harness::Commands::CreateAgent do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }

    it "cria e persiste o profile; emite :agent_created; devolve com symbols normalizados" do
      profile = handler.call(cmd(:create_agent, {
                                    "id" => "bia", "model" => "deepseek-chat", "provider" => "deepseek",
                                    "tools_allow" => %w[menu], "policies" => %w[tool_allowlist],
                                    "limits" => { "tool_timeout" => 30 }, "memory" => true
                                  }))
      expect(profile.id).to eq("bia")
      expect(profile.provider).to eq(:deepseek)            # symbol
      expect(profile.policies).to eq([:tool_allowlist])    # symbol
      expect(profile.limits[:tool_timeout]).to eq(30)
      expect(source.fetch("bia")).not_to be_nil            # persistido
      expect(events.map(&:type)).to eq([:agent_created])
    end

    it "id e model obrigatórios" do
      expect { handler.call(cmd(:create_agent, { "model" => "m" })) }.to raise_error(Harness::ValidationError, /id/)
      expect { handler.call(cmd(:create_agent, { "id" => "x" })) }.to raise_error(Harness::ValidationError, /model/)
    end

    it "id duplicado -> ValidationError (não sobrescreve)" do
      handler.call(cmd(:create_agent, { "id" => "bia", "model" => "m" }))
      expect { handler.call(cmd(:create_agent, { "id" => "bia", "model" => "m2" })) }
        .to raise_error(Harness::ValidationError, /já existe/)
    end
  end

  describe Harness::Commands::UpdateAgent do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }
    before { source.put(Harness::AgentProfile.build(id: "bia", model: "m1", provider: :deepseek, skills: %w[pedido])) }

    it "faz merge do patch (só o enviado muda); emite :agent_updated" do
      profile = handler.call(cmd(:update_agent, { "id" => "bia", "model" => "m2" }))
      expect(profile.model).to eq("m2")
      expect(profile.skills).to eq(%w[pedido])   # preservado (não estava no patch)
      expect(profile.provider).to eq(:deepseek)  # preservado
      expect(events.map(&:type)).to include(:agent_updated)
    end

    it "agente inexistente -> NotFoundError" do
      expect { handler.call(cmd(:update_agent, { "id" => "nope", "model" => "m" })) }
        .to raise_error(Harness::NotFoundError)
    end
  end

  describe Harness::Commands::SetAgentTools do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }
    before { source.put(Harness::AgentProfile.build(id: "bia", model: "m", tools_allow: %w[a b])) }

    it "ajusta allow/deny; nil allow = todas" do
      p = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => %w[menu], "deny" => %w[calc] }))
      expect(p.tools_allow).to eq(%w[menu])
      expect(p.tools_deny).to eq(%w[calc])
      p2 = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => nil }))
      expect(p2.tools_allow).to be_nil
    end

    it "allow não-lista -> ValidationError" do
      expect { handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => "x" })) }
        .to raise_error(Harness::ValidationError)
    end

    # Fase 7/D4/F5 (Etapa C): allow_groups só sobrescreve se a chave vier.
    it "seta allow_groups quando presente; preserva quando ausente" do
      p = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow_groups" => %w[b2b] }))
      expect(p.tools_allow_groups).to eq(%w[b2b])
      p2 = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => %w[x] })) # sem allow_groups
      expect(p2.tools_allow_groups).to eq(%w[b2b]) # preservado
    end

    it "allow_groups não-lista -> ValidationError" do
      expect { handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow_groups" => "x" })) }
        .to raise_error(Harness::ValidationError, /allow_groups/)
    end
  end

  describe Harness::Commands::DeleteAgent do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }

    it "remove o agente e devolve o removido; emite :agent_deleted" do
      source.put(Harness::AgentProfile.build(id: "bia", model: "m"))
      removed = handler.call(cmd(:delete_agent, { "id" => "bia" }))
      expect(removed.id).to eq("bia")
      expect(source.fetch("bia")).to be_nil
      expect(events.map(&:type)).to include(:agent_deleted)
    end

    it "inexistente -> NotFoundError" do
      expect { handler.call(cmd(:delete_agent, { "id" => "nope" })) }.to raise_error(Harness::NotFoundError)
    end
  end
end
