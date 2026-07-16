# frozen_string_literal: true

require "spec_helper"

# Fase 5 Etapa A: guarda de egress (SSRF) das tools por dados.
# Usa IPs LITERAIS (não bate DNS) exceto onde o teste exige.
RSpec.describe Harness::EgressGuard do
  it "permite https p/ destino público" do
    expect(described_class.violation("https://8.8.8.8/x")).to be_nil
  end

  it "bloqueia http por padrão; permite com allow_http" do
    expect(described_class.violation("http://8.8.8.8/x")).to match(/http não permitido/)
    expect(described_class.violation("http://8.8.8.8/x", allow_http: true)).to be_nil
  end

  it "bloqueia esquema não-http" do
    expect(described_class.violation("ftp://8.8.8.8/x")).to match(/esquema/)
  end

  it "bloqueia loopback, redes privadas, link-local/metadata e IPv6 local" do
    {
      "https://127.0.0.1/x" => /privada/,
      "https://10.0.0.1/x" => /privada/,
      "https://192.168.1.1/x" => /privada/,
      "https://172.16.5.5/x" => /privada/,
      "https://169.254.169.254/latest/meta-data" => /privada/, # metadata da cloud
      "https://[::1]/x" => /privada/
    }.each do |url, re|
      expect(described_class.violation(url)).to match(re), "esperava bloquear #{url}"
    end
  end

  it "bloqueia host ausente" do
    expect(described_class.violation("https:///x")).to match(/host ausente/)
  end

  it "allowlist: só hosts listados passam" do
    expect(described_class.violation("https://8.8.8.8/x", host_allowlist: ["8.8.8.8"])).to be_nil
    expect(described_class.violation("https://1.1.1.1/x", host_allowlist: ["8.8.8.8"])).to match(/allowlist/)
  end

  describe "allow_private (API interna de confiança, NF4)" do
    it "por padrão bloqueia loopback/privado" do
      expect(described_class.violation("http://127.0.0.1:3000/api/internal/x", allow_http: true))
        .to match(/privada/)
    end

    it "allow_private libera o destino privado" do
      expect(described_class.violation("http://127.0.0.1:3000/api/internal/x",
                                       allow_http: true, allow_private: true)).to be_nil
    end

    it "allow_private + host_allowlist: libera só o host de confiança (defesa em profundidade)" do
      opts = { allow_http: true, allow_private: true, host_allowlist: ["localhost"] }
      expect(described_class.violation("http://localhost:3000/api/internal/x", **opts)).to be_nil
      # um host privado fora da allowlist ainda é barrado (pela allowlist, antes do IP)
      expect(described_class.violation("http://127.0.0.1:3000/x", **opts)).to match(/allowlist/)
    end

    it "não afeta o esquema: http continua exigindo allow_http" do
      expect(described_class.violation("http://127.0.0.1/x", allow_private: true)).to match(/http não permitido/)
    end
  end
end
