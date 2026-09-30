# frozen_string_literal: true

require "spec_helper"
require "insika/llm_http_adapter"

RSpec.describe Insika::LLMHTTPAdapter do
  # Faraday's net_http adapter builds a CA store from the system bundle for each
  # connection, and RubyLLM builds a connection per chat: every chat parsed the
  # whole bundle again to verify the provider's certificate.
  it "verifies against the process-wide default store instead of loading a new one" do
    adapter = described_class.new(->(_env) {})

    expect(adapter.send(:ssl_cert_store, {})).to be(OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE)
  end

  it "keeps a cert_store the caller passes" do
    store = OpenSSL::X509::Store.new

    expect(described_class.new(->(_env) {}).send(:ssl_cert_store, { cert_store: store })).to be(store)
  end

  it "is registered as a Faraday adapter RubyLLM can select by name" do
    expect(Faraday::Adapter.lookup_middleware(:insika_net_http)).to be(described_class)
  end
end
