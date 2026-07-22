# frozen_string_literal: true

require "spec_helper"

# Phase 5 Stage A: versioned + masked store for data-defined tools.
RSpec.describe Harness::ToolStore do
  subject(:store) { described_class.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }

  def def_attrs(name: "cep", **over)
    {
      name: name,
      description: "Consulta CEP",
      parameters: [{ name: "cep", type: "string", required: true }],
      request: { method: "GET", url: "https://viacep.com.br/ws/{{cep}}/json" },
      response: { extract: "json_path", path: "localidade" }
    }.merge(over)
  end

  def with_secret(name: "api", token: "SECRET-123")
    {
      name: name, description: "chama API",
      parameters: [],
      request: { method: "POST", url: "https://api.test/x",
                 headers: { "Authorization" => "Bearer #{token}", "X-Trace" => "on" } },
      secret_headers: ["Authorization"]
    }
  end

  it "write/get round-trip; names/all list; all_raw for overlay" do
    store.write(def_attrs(name: "cep"))
    store.write(def_attrs(name: "clima", request: { url: "https://c.test/{{cep}}" }))

    expect(store.get("cep")["name"]).to eq("cep")
    expect(store.names).to eq(%w[cep clima])            # lexicographic
    expect(store.all.map { |d| d["name"] }).to contain_exactly("cep", "clima")
    expect(store.all_raw.size).to eq(2)
  end

  it "validates the definition on write (delegates to ToolDefinition)" do
    expect { store.write(def_attrs(name: "Bad Name")) }
      .to raise_error(Harness::ValidationError, /name/)
  end

  it "masks secret headers in get/all; get_raw returns the real one" do
    store.write(with_secret(token: "SECRET-123"))

    masked = store.get("api")
    expect(masked["request"]["headers"]["Authorization"]).to eq(Harness::SecretMasking::SENTINEL)
    expect(masked["request"]["headers"]["X-Trace"]).to eq("on")   # non-secret passes through
    expect(store.get_raw("api")["request"]["headers"]["Authorization"]).to eq("Bearer SECRET-123")
  end

  it "0 leaks: the real secret never appears in the display read" do
    store.write(with_secret(token: "SUPERSECRET"))
    dump = [store.get("api"), store.all, store.versions("api")].inspect
    expect(dump).not_to include("SUPERSECRET")
  end

  it "sentinel sent back preserves the secret; a new string replaces it" do
    store.write(with_secret(token: "ORIG"))
    # UI resends the masked value (sentinel) -> preserves ORIG
    store.write(with_secret.merge(request: {
                                    method: "POST", url: "https://api.test/x",
                                    headers: { "Authorization" => Harness::SecretMasking::SENTINEL, "X-Trace" => "off" }
                                  }))
    expect(store.get_raw("api")["request"]["headers"]["Authorization"]).to eq("Bearer ORIG")
    expect(store.get_raw("api")["request"]["headers"]["X-Trace"]).to eq("off")

    # a new string replaces it
    store.write(with_secret(token: "NOVO"))
    expect(store.get_raw("api")["request"]["headers"]["Authorization"]).to eq("Bearer NOVO")
  end

  it "overwriting creates a version; create_only refuses" do
    store.write(def_attrs(name: "cep", description: "v1"))
    store.write(def_attrs(name: "cep", description: "v2"))
    expect(store.versions("cep").map { |h| h["definition"]["description"] }).to eq(["v1"])
    expect { store.write(def_attrs(name: "cep"), create_only: true) }
      .to raise_error(Harness::ValidationError, /already exists/)
  end

  it "restore reverts to an old version (and preserves the real secret)" do
    store.write(with_secret(token: "V1"))
    store.write(with_secret(token: "V2"))
    store.restore("api", 0)
    expect(store.get_raw("api")["request"]["headers"]["Authorization"]).to eq("Bearer V1")
  end

  it "delete -> bool" do
    store.write(def_attrs(name: "cep"))
    expect(store.delete("cep")).to be(true)
    expect(store.delete("cep")).to be(false)
  end
end
