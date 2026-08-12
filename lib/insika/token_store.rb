# frozen_string_literal: true

require "securerandom"
require "digest"
require "time"

module Insika
  # Multi-tenant credentials (WS1): per-tenant tokens plus the operator token,
  # stored ONLY as SHA-256 hashes — the plaintext is returned once at issue time
  # and is never persisted, logged or evented. Every resolution is a hash lookup,
  # so reading the store yields nothing usable. Behind any Insika::Store, like
  # the other domain stores.
  #
  # A record describes ONE principal the edge can resolve a Bearer to:
  #   role:      "operator" (tenant_id nil — the historical single credential)
  #              "tenant"   (scoped to tenant_id)
  #   status:    "active" | "revoked"
  # A revoked record stops resolving immediately; a tenant's rotation is
  # revoke-all + issue (the spec's rule — revoking one tenant's token never
  # touches another tenant's: every cell is (id)- or (hash)-scoped cells).
  class TokenStore
    SCOPE = "tenant_tokens"

    Record = Data.define(:id, :token_hash, :role, :tenant_id, :label,
                         :status, :created_at, :revoked_at) do
      def active? = status.to_s == "active"
      def tenant? = role.to_s == "tenant"
      def to_h
        { id: id, role: role, tenant_id: tenant_id, label: label,
          status: status, created_at: created_at, revoked_at: revoked_at }
      end
    end

    # The token a caller receives from a successful issue/rotate — the ONLY
    # moment the plaintext exists in the process. `token` is never stored.
    Issue = Data.define(:id, :token)

    def initialize(store:)
      @store = store
    end

    # Issues a token for tenant_id (nil = an OPERATOR token). -> Issue. The
    # token is shown exactly once; there is no `get_token` — lost = rotate.
    def issue(tenant_id: nil, label: "default")
      token = SecureRandom.hex(32)
      hash = digest(token)
      id = SecureRandom.uuid
      @store.transaction do
        @store.set(SCOPE, record_key(id), {
                     "id" => id, "token_hash" => hash,
                     "role" => tenant_id ? "tenant" : "operator",
                     "tenant_id" => tenant_id, "label" => label.to_s,
                     "status" => "active",
                     "created_at" => Time.now.utc.iso8601, "revoked_at" => nil
                   })
        @store.set(SCOPE, hash_key(hash), id)
      end
      Issue.new(id: id, token: token)
    end

    # Active-token record for token_id; a revoked one reads WHO it was but not
    # as resolvable. -> Record | nil.
    def find(id)
      return nil if id.to_s.empty?

      record = @store.get(SCOPE, record_key(id.to_s))
      record && to_record(record)
    end

    # The edge resolution: -> Record (active) | nil. A revoked token is
    # indistinguishable from a missing one (fail-closed: the Bearer just 401s).
    def resolve(token)
      return nil if token.to_s.empty?

      id = @store.get(SCOPE, hash_key(digest(token)))
      return nil if id.nil?

      record = to_record(@store.get(SCOPE, record_key(id)))
      record&.active? ? record : nil
    end

    # -> bool: true only for an ACTIVE record (revoking an already-revoked/unknown
    # id is false — a no-op, never an error).
    def revoke(id)
      record = find(id)
      return false unless record&.active?

      flipped = record.to_h.merge(status: "revoked", revoked_at: Time.now.utc.iso8601)
      @store.set(SCOPE, record_key(id), stringify(flipped))
      true
    end

    # Revokes every ACTIVE token of a tenant; the hash-index cells stay (they
    # resolve to a revoked record -> nil). -> count of records revoked. Does NOT
    # touch the operator token or any other tenant.
    def revoke_all(tenant_id:)
      ids = active_token_ids.select do |id|
        record = to_record(@store.get(SCOPE, record_key(id)))
        record&.tenant? && record.tenant_id.to_s == tenant_id.to_s
      end
      ids.count { |id| revoke(id) }
    end

    # Rotation: revoke the tenant's active tokens, issue a fresh one. Both in
    # one transaction -> a crashed half-rotation never leaves the tenant with
    # NOTHING valid. -> { revoked: n, issue: Issue }.
    def rotate(tenant_id:, label: "default", now: Time.now)
      @store.transaction do
        revoked = revoke_all(tenant_id: tenant_id)
        { revoked: revoked, issue: issue(tenant_id: tenant_id, label: label) }
      end
    end

    # Every active token id (used by revoke_all). Reads the id-keyed cells.
    def active_token_ids
      @store.list(SCOPE, RECORD_PREFIX).filter_map do |key|
        id = key.delete_prefix(RECORD_PREFIX)
        record = @store.get(SCOPE, record_key(id))
        record && record["status"] == "active" ? id : nil
      end
    end

    private

    def digest(token)
      Digest::SHA256.hexdigest(token)
    end

    RECORD_PREFIX = "r:"
    HASH_PREFIX = "h:"

    def record_key(id) = "#{RECORD_PREFIX}#{id}"
    def hash_key(hash) = "#{HASH_PREFIX}#{hash}"

    def to_record(record)
      return nil if record.nil?

      Record.new(
        id: record["id"], token_hash: record["token_hash"],
        role: record["role"], tenant_id: record["tenant_id"],
        label: record["label"], status: record["status"],
        created_at: record["created_at"], revoked_at: record["revoked_at"]
      )
    end

    def stringify(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
  end
end