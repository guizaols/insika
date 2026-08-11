# frozen_string_literal: true

require "time"

module Insika
  # The ACCEPTED state of an agent's golden set (promoted to a store
  # by). One record per agent in the ConfigStore (scope "baselines"):
  #
  #   { "at" => iso8601, "cases" => { "<case id>" => { "pass" => bool, "score" => n } } }
  #
  # Exactly the shape `Evals::Baseline.snapshot` already produces, so the file and
  # the record are the same document in two places — no converter to keep honest,
  # the same discipline `GoldenStore` applies to the corpus.
  #
  # **Why it had to leave the file.** `evals/baseline.json` works fine for the CLI,
  # which runs from a checkout. The refinement gate does not: it runs inside a
  # Railway deployment, scores a throwaway clone against the accepted state, and
  # there is no checkout there to read. A gate that fell back to "no baseline found,
  # nothing regressed" would be the most dangerous default in the system — so the
  # baseline became a per-agent record, and the gate refuses when it is missing.
  #
  # The file stays the export format and the seed for a fresh deploy
  # (`insika evals:baseline import|export`), for the same reason the goldens' YAML
  # does. It is also still what `evals/run.rb --gate` reads for the pre-merge check,
  # which is a checkout-side job and should stay one.
  #
  # Per AGENT and not one blob, unlike the file: a deployment serves many agents, a
  # refinement run is about exactly one, and re-baselining the store after fixing
  # agent A must not silently accept agent B's current state.
  class BaselineStore
    SCOPE = "baselines"

    def initialize(config_store:)
      @cs = config_store
    end

    # -> { "at" =>, "cases" => {…} } | nil. nil means NOT RECORDED, which every
    # caller must treat as "cannot gate", never as "nothing regressed".
    def get(agent_id)
      @cs.get(SCOPE, agent_id.to_s)
    end

    # -> the stored record. `snapshot` is `Evals::Baseline.snapshot` output (or the
    # equivalent hash); `at` is stamped here when the snapshot carries none.
    def put(agent_id, snapshot, at: nil)
      raw = Coercion.deep_stringify(snapshot || {})
      cases = raw["cases"]
      raise Insika::ValidationError, "baseline needs a 'cases' mapping" unless cases.is_a?(Hash)

      record = { "at" => Coercion.presence(raw["at"]) || at || timestamp, "cases" => cases }
      @cs.put(SCOPE, agent_id.to_s, record)
      record
    end

    # -> bool (did it exist?). Removing a baseline disables the gate for that agent,
    # which is the honest consequence and not a side effect worth hiding.
    def delete(agent_id) = !!@cs.delete(SCOPE, agent_id.to_s)

    # -> [String] agents with a recorded baseline.
    def agents = @cs.keys(SCOPE)

    # How many cases the accepted state covers. `0` and `nil` are different answers:
    # nil = never recorded, 0 = recorded and empty (every case was skipped), and only
    # the first is a configuration mistake.
    def size(agent_id)
      record = get(agent_id)
      record && (record["cases"] || {}).size
    end

    private

    def timestamp = Time.now.utc.iso8601
  end
end
