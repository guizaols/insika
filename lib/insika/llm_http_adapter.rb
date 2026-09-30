# frozen_string_literal: true

require "openssl"
require "faraday"
require "faraday/net_http"

module Insika
  # Faraday's net_http adapter with ONE certificate store per process.
  #
  # The stock adapter builds a store from the system CA bundle for each
  # connection, and RubyLLM builds a connection per chat, so every chat parsed
  # the whole bundle again to verify the provider's certificate — CPU paid on
  # every turn. This one verifies against OpenSSL's default store (the same
  # system paths, the store Net::HTTP already shares). A cert_store passed in
  # the connection's ssl options still wins, and a ca_file/ca_path gets the stock
  # private store: OpenSSL loads those INTO the store it is given, which would
  # make one connection's CA trusted by every HTTPS call in the process.
  #
  # Select it with `RubyLLM.configure { |c| c.faraday_adapter = :insika_net_http }`.
  class LLMHTTPAdapter < Faraday::Adapter::NetHttp
    private

    def ssl_cert_store(ssl)
      return super if ssl[:ca_file] || ssl[:ca_path]

      ssl[:cert_store] || OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE
    end
  end
end

Faraday::Adapter.register_middleware(insika_net_http: Insika::LLMHTTPAdapter)
