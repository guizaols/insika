# frozen_string_literal: true

require "openssl"
require "time"

module Insika
  # The signed-link half of the artifact serving surface. The signing key
  # lives in the environment (INSIKA_ARTIFACT_SIGNING_KEY), never in a store:
  # HMAC-SHA256 over (id, expiry), verified in constant time on the serve
  # path. Without the key, only the authenticated Studio URL exists.
  #
  # The token is deterministic for a (id, expiry) pair — no nonce, on purpose:
  # a rotated key invalidates every outstanding link, which is the documented
  # rotation behavior (an artifact link is short-lived by TTL, not by
  # unguessability of a single-use nonce).
  module ArtifactSigning
    module_function

    # The route's path shapes — the ONE place the URL grammar lives, shared
    # by the tool (which hands URLs to the model) and the route (which serves
    # them).
    AUTHENTICATED_PATH = "/studio/artifacts/%{id}/content"
    SIGNED_PATH = "/studio/artifacts/s/%{id}?exp=%{exp}&sig=%{sig}"

    # -> hex token (64 chars) | nil when the key is blank (no signed surface).
    def sign(id:, expires_at:, key:)
      key = key.to_s
      return nil if key.empty?

      OpenSSL::HMAC.hexdigest("SHA256", key, payload(id, expires_at))
    end

    # -> bool. Re-signs the (id, exp) pair the route extracted from the URL
    # and compares in constant time; an expired link or a blank key/token is
    # false (the route 404s — no oracle). Expiry is inclusive: a link at its
    # exact `expires_at` still verifies.
    def valid?(id:, token:, key:, exp:, now: Time.now.utc)
      token = token.to_s
      key = key.to_s
      return false if key.empty? || token.empty?

      expected = sign(id: id.to_s, expires_at: exp, key: key)
      return false unless expected && secure_compare(expected, token)

      exp_time = exp.is_a?(Time) ? exp.to_time.utc : Time.iso8601(exp.to_s).utc
      now.to_time <= exp_time
    rescue ArgumentError, TypeError
      false # a malformed exp (or a time that never parses) is an invalid link
    end

    # -> the artifact's shareable URL. With a key + ttl: the signed link
    # (shares OUTSIDE the Studio, expires). Without: the authenticated Studio
    # content URL. An empty base yields the relative path — still openable in
    # the Studio, useless on a channel (the doc says exactly that).
    def url_for(id:, base: nil, key: nil, ttl: nil, now: Time.now.utc)
      base = base.to_s.sub(%r{/\z}, "")
      if key && key.to_s.length.positive? && ttl && ttl.to_i.positive?
        exp = (now.to_time + ttl.to_i).utc.iso8601
        sig = sign(id: id.to_s, expires_at: exp, key: key)
        "#{base}#{format(SIGNED_PATH, id: id, exp: exp, sig: sig)}"
      else
        "#{base}#{format(AUTHENTICATED_PATH, id: id)}"
      end
    end

    # Constant-time comparison of two hex strings. Length-independent compare
    # is fine here: the token length is public (fixed by the algorithm).
    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
    end

    # The signed payload: id + expiry — both are what the route must not let
    # an attacker change. The id is the store key; the expiry bounds the link.
    # Accepts a Time or an ISO8601 String (the route passes the query param).
    def payload(id, expires_at)
      time = expires_at.is_a?(Time) ? expires_at.utc : Time.iso8601(expires_at.to_s).utc
      "#{id}:#{time.iso8601}"
    end
  end
end