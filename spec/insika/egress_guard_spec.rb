# frozen_string_literal: true

require "spec_helper"

# egress guard (SSRF) for the data-driven tools.
# Uses LITERAL IPs (no DNS lookup) except where the test requires it.
RSpec.describe Insika::EgressGuard do
  it "allows https to a public destination" do
    expect(described_class.violation("https://8.8.8.8/x")).to be_nil
  end

  it "blocks http by default; allows with allow_http" do
    expect(described_class.violation("http://8.8.8.8/x")).to match(/http not allowed/)
    expect(described_class.violation("http://8.8.8.8/x", allow_http: true)).to be_nil
  end

  it "blocks non-http scheme" do
    expect(described_class.violation("ftp://8.8.8.8/x")).to match(/scheme/)
  end

  it "blocks loopback, private networks, link-local/metadata and local IPv6" do
    {
      "https://127.0.0.1/x" => /private-network/,
      "https://10.0.0.1/x" => /private-network/,
      "https://192.168.1.1/x" => /private-network/,
      "https://172.16.5.5/x" => /private-network/,
      "https://169.254.169.254/latest/meta-data" => /private-network/, # cloud metadata
      "https://[::1]/x" => /private-network/
    }.each do |url, re|
      expect(described_class.violation(url)).to match(re), "expected to block #{url}"
    end
  end

  it "blocks missing host" do
    expect(described_class.violation("https:///x")).to match(/missing host/)
  end

  it "allowlist: only listed hosts pass" do
    expect(described_class.violation("https://8.8.8.8/x", host_allowlist: ["8.8.8.8"])).to be_nil
    expect(described_class.violation("https://1.1.1.1/x", host_allowlist: ["8.8.8.8"])).to match(/allowlist/)
  end

  describe "allow_private (trusted internal API)" do
    it "blocks loopback/private by default" do
      expect(described_class.violation("http://127.0.0.1:3000/api/internal/x", allow_http: true))
        .to match(/private-network/)
    end

    it "allow_private permits the private destination" do
      expect(described_class.violation("http://127.0.0.1:3000/api/internal/x",
                                       allow_http: true, allow_private: true)).to be_nil
    end

    it "allow_private + host_allowlist: permits only the trusted host (defense in depth)" do
      opts = { allow_http: true, allow_private: true, host_allowlist: ["localhost"] }
      expect(described_class.violation("http://localhost:3000/api/internal/x", **opts)).to be_nil
      # a private host outside the allowlist is still blocked (by the allowlist, before the IP)
      expect(described_class.violation("http://127.0.0.1:3000/x", **opts)).to match(/allowlist/)
    end

    it "doesn't affect the scheme: http still requires allow_http" do
      expect(described_class.violation("http://127.0.0.1/x", allow_private: true)).to match(/http not allowed/)
    end
  end
end
