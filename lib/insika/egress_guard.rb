# frozen_string_literal: true

require "uri"
require "ipaddr"
require "resolv"

module Insika
  # EGRESS guard for data-tools (SSRF). A data-tool makes a server-side HTTP
  # request with a URL coming from UI-editable config — without a guard, it's an
  # SSRF vector (hitting cloud metadata, internal services, localhost). Rules
  # (spec):
  #   - https only by default (http requires explicit opt-in);
  #   - host required;
  #   - optional host allowlist (when present, only it passes);
  #   - resolves the host and BLOCKS if ANY address falls into a private/
  #     loopback/link-local/metadata network (defense against DNS rebinding);
  #   - `allow_private:` (opt-in) ALLOWS the private target — to reach a trusted
  #     INTERNAL API (the consumer's /api/internal/* comes in via an
  #     allowlist). Dangerous without `host_allowlist`: PIN it to a known host.
  #     Default false = strict guard.
  #
  # `violation(url, ...)` returns nil (ok) or a String with the reason — the
  # DataDefinedTool turns the reason into `{ error: }` to the model (never raises).
  module EgressGuard
    BLOCKED = [
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
      "198.18.0.0/15", "::1/128", "fc00::/7", "fe80::/10", "::ffff:0:0/96"
    ].map { |c| IPAddr.new(c) }.freeze

    module_function

    # -> nil (allowed) | String (block reason).
    def violation(url, allow_http: false, host_allowlist: nil, allow_private: false)
      uri = begin
        URI.parse(url.to_s)
      rescue URI::InvalidURIError
        return "invalid URL"
      end

      return "unsupported scheme" unless %w[http https].include?(uri.scheme)
      return "http not allowed (use https)" if uri.scheme == "http" && !allow_http

      host = uri.host
      return "missing host" if host.nil? || host.empty?
      return "host not in allowlist" if host_allowlist && !host_allowlist.include?(host)

      addrs = resolve(host)
      return "host did not resolve" if addrs.empty?
      # allow_private skips the private-network block (trusted internal API,
      # Without it, a private/loopback/metadata target is always blocked.
      return "private-network destination blocked" if !allow_private && addrs.any? { |ip| blocked?(ip) }

      nil
    end

    # Literal host (IP) -> itself; hostname -> resolve via DNS. -> [IPAddr].
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
