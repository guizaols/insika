# frozen_string_literal: true

require "uri"
require "ipaddr"
require "resolv"

module Harness
  # Guarda de EGRESS para tools por dados (SSRF). Uma data-tool faz requisição HTTP
  # server-side com URL vinda de config editável na UI — sem guarda, é vetor de
  # SSRF (bater no metadata da cloud, em serviços internos, em localhost). Regras
  # (NF2 da spec):
  #   - só https por padrão (http exige opt-in explícito);
  #   - host obrigatório;
  #   - allowlist de hosts opcional (quando presente, só ela passa);
  #   - resolve o host e BLOQUEIA se QUALQUER endereço cair em rede privada/
  #     loopback/link-local/metadata (defesa contra DNS rebinding).
  #
  # `violation(url, ...)` devolve nil (ok) ou uma String com o motivo — o
  # DataDefinedTool transforma o motivo em `{ error: }` ao modelo (nunca levanta).
  module EgressGuard
    BLOCKED = [
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
      "198.18.0.0/15", "::1/128", "fc00::/7", "fe80::/10", "::ffff:0:0/96"
    ].map { |c| IPAddr.new(c) }.freeze

    module_function

    # -> nil (permitido) | String (motivo do bloqueio).
    def violation(url, allow_http: false, host_allowlist: nil)
      uri = begin
        URI.parse(url.to_s)
      rescue URI::InvalidURIError
        return "URL inválida"
      end

      return "esquema não suportado" unless %w[http https].include?(uri.scheme)
      return "http não permitido (use https)" if uri.scheme == "http" && !allow_http

      host = uri.host
      return "host ausente" if host.nil? || host.empty?
      return "host fora da allowlist" if host_allowlist && !host_allowlist.include?(host)

      addrs = resolve(host)
      return "host não resolveu" if addrs.empty?
      return "destino em rede privada bloqueado" if addrs.any? { |ip| blocked?(ip) }

      nil
    end

    # Host literal (IP) -> ele mesmo; hostname -> resolve via DNS. -> [IPAddr].
    def resolve(host)
      literal = ip_or_nil(host.delete_prefix("[").delete_suffix("]"))
      return [literal] if literal

      Resolv.getaddresses(host).filter_map { |a| ip_or_nil(a) }
    rescue Resolv::ResolvError, SocketError
      []
    end

    def blocked?(ip) = BLOCKED.any? { |net| net.include?(ip) }

    def ip_or_nil(str)
      IPAddr.new(str)
    rescue IPAddr::InvalidAddressError
      nil
    end
  end
end
