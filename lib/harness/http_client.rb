# frozen_string_literal: true

require "net/http"
require "uri"

module Harness
  # Cliente HTTP default das tools por dados. Net::HTTP (stdlib, zero-dep — §10 da
  # spec) com timeouts de socket próprios (mitiga bloqueio do reactor mesmo se o
  # timer do envelope não disparar) e CAP de tamanho de resposta por streaming
  # (NF2, evita OOM). É INJETÁVEL: os testes passam um dublê (nenhum bate rede);
  # a Etapa C pode trocar por async-http sem tocar no DataDefinedTool.
  #
  # Contrato: request(method:, url:, headers:, body:, timeout:) -> { status:, body: }.
  class HttpClient
    DEFAULT_TIMEOUT = 30
    MAX_BYTES = 1_000_000 # 1 MB

    class ResponseTooLarge < Harness::Error; end

    def initialize(max_bytes: MAX_BYTES)
      @max_bytes = max_bytes
    end

    def request(method:, url:, headers: {}, body: nil, timeout: nil)
      uri = URI.parse(url)
      req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body && !body.to_s.empty?

      t = timeout || DEFAULT_TIMEOUT
      opts = { use_ssl: uri.scheme == "https", open_timeout: t, read_timeout: t }
      Net::HTTP.start(uri.host, uri.port, opts) do |http|
        result = nil
        http.request(req) do |resp|
          collected = +""
          resp.read_body do |chunk|
            collected << chunk
            raise ResponseTooLarge, "resposta excede #{@max_bytes} bytes" if collected.bytesize > @max_bytes
          end
          result = { status: resp.code.to_i, body: collected }
        end
        result
      end
    end
  end
end
