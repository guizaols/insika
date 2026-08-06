# frozen_string_literal: true

require "fileutils"
require "time"
require "yaml"

module Insika
  # AUTHORED eval cases (RFC-0008 §3.1, promoted to a store by RFC-0013 §3.7).
  #
  # A golden case used to be a YAML file in `evals/golden/`, which means only someone
  # with a checkout and a text editor could add one. The rubric is the part of an eval
  # a domain owner can actually write ("consults the coupon by tool and does NOT invent
  # a code") — so it has to be authorable where they already work, the Studio.
  #
  # One record per case in the ConfigStore (scope "goldens"):
  #   { "case" => { "id" =>, "agent" =>, "turns" => [...], "expect" => {...} },
  #     "updated_at" => iso8601 }
  #
  # The stored shape is the SAME mapping the YAML file holds, and every write is
  # validated by `Evals::GoldenLoader.build` — the one validator, so a case authored in
  # the Studio and a case read from disk cannot diverge. `evals/golden/**` stays the
  # export format and the seed for a fresh deploy (`insika evals:import`), for the same
  # reason the knowledge RFC keeps markdown as both: no converter to keep honest.
  #
  # No version history here, unlike the prompt/skill stores: the corpus on disk IS the
  # backup, and re-importing restores it.
  class GoldenStore
    SCOPE = "goldens"

    def initialize(config_store:)
      @cs = config_store
    end

    # Upsert. `raw` is the case mapping (string or symbol keys), validated before it
    # lands. -> Evals::Golden. InvalidGolden if malformed — a silently dropped case is
    # a hole in the safety net, which is why the loader raises instead of skipping.
    def write(raw, path: nil)
      golden = Evals::GoldenLoader.build(Coercion.deep_stringify(raw), source: "(store)")
      record = { "case" => case_hash(golden), "updated_at" => timestamp }
      # Remember where it came from, so an export reproduces the corpus LAYOUT instead
      # of renaming every file. The curated corpus groups the safety suite by PURPOSE
      # (`safety/`) while its cases belong to an example agent — deriving the path from
      # the agent would scatter them. An edit keeps whatever path it already had.
      record["path"] = Coercion.presence(path) || @cs.get(SCOPE, golden.id)&.fetch("path", nil)
      @cs.put(SCOPE, golden.id, record.compact)
      golden
    end

    # -> Evals::Golden | nil. A stored case that no longer validates surfaces as nil
    # rather than raising here; `insika doctor`-style sweeps are the place to shout.
    def find(id)
      record = @cs.get(SCOPE, id.to_s)
      record && build(record)
    end

    # -> [String] case ids, lexicographic (a stable run order, like the file loader's
    # sort by path).
    def ids = @cs.keys(SCOPE)

    # -> [Evals::Golden] every valid case, in id order.
    def all = ids.filter_map { |id| find(id) }

    # -> [Evals::Golden] one agent's cases.
    def for_agent(agent_id) = all.select { |g| g.agent == agent_id.to_s }

    # -> [String] ids whose stored mapping no longer validates (an edit that broke the
    # shape). The Studio shows these; they never silently vanish from a run.
    def invalid
      ids.reject { |id| find(id) }
    end

    # -> bool (did it exist?)
    def delete(id) = @cs.delete(SCOPE, id.to_s)

    # Bulk import from the corpus on disk. Returns the ids written. `overwrite: false`
    # keeps an already-authored case (the store wins over the seed, same rule the
    # SkillCatalog overlay uses).
    def import_dir(dir, overwrite: true)
      root = File.expand_path(dir)
      Evals::GoldenLoader.load_dir(dir).filter_map do |golden|
        next if !overwrite && @cs.get(SCOPE, golden.id)

        # Expand both sides: the loader's `source` is whatever shape `dir` was given in
        # (a relative glob stays relative), so comparing raw strings would leave the
        # corpus prefix inside the stored path.
        relative = File.expand_path(golden.source.to_s).delete_prefix("#{root}/")
        write(case_hash(golden), path: relative).id
      end
    end

    # The export format IS the import format, written at the path the case came from
    # (falling back to `<agent>/<id>.yml` for a case authored in the Studio). -> [paths]
    #
    # It is NOT a faithful copy of the curated corpus: `YAML.dump` drops the comments
    # those files carry, and each one explains what its case is for. So exporting over
    # an existing corpus demands `force` — losing that prose silently would be a bad
    # trade for a convenience.
    def export_dir(dir, force: false)
      existing = Dir.glob(File.join(dir, "**", "*.{yml,yaml}"))
      if existing.any? && !force
        raise Insika::ValidationError,
              "#{dir} already holds #{existing.size} case file(s); exporting rewrites them and " \
              "DROPS their comments — pass --force to accept that, or export somewhere else"
      end

      all.map do |golden|
        path = File.join(dir, path_of(golden))
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, YAML.dump(case_hash(golden)))
        path
      end
    end

    private

    def path_of(golden)
      Coercion.presence(@cs.get(SCOPE, golden.id)&.fetch("path", nil)) ||
        File.join(golden.agent, "#{golden.id}.yml")
    end

    def build(record)
      Evals::GoldenLoader.build(record["case"] || {}, source: "(store)")
    rescue Evals::GoldenLoader::InvalidGolden
      nil
    end

    # Golden -> the plain mapping (what YAML holds and what the store persists).
    # `source` is a load-time detail, never part of the case.
    def case_hash(golden)
      { "id" => golden.id, "agent" => golden.agent,
        "turns" => golden.turns, "expect" => golden.expect }
    end

    def timestamp = Time.now.utc.iso8601
  end
end
