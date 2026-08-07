# frozen_string_literal: true

require "securerandom"

module Insika
  module Refinement
    # ONE proposed change to an agent's instruction files (RFC-0013 §3.4). Data, not
    # a diff of free text, and that is the load-bearing decision of the whole phase:
    #
    #   · an ANCHORED edit is reviewable — the operator reads three lines, not a
    #     rewritten file, and can tell in seconds whether to approve it;
    #   · it is ATTRIBUTABLE — when the gate's score moves, it moved because of an
    #     edit you can point at, not because a model rewrote the prompt;
    #   · it is STALE-CHECKABLE — `before` must still match the file, so a proposal
    #     built from a snapshot cannot silently clobber an edit made since.
    #
    # A candidate arrives from anywhere (a model, the Studio, a JSON payload) and is
    # always built through `Candidate.build`, which is the only place the bounds and
    # the write allowlist are enforced. An edit that violates one is DROPPED with a
    # reason rather than failing the whole candidate: a proposal with two good edits
    # and one stale one is worth gating, and the operator should see what fell off.
    Edit = Data.define(:file, :op, :anchor, :before, :after, :addresses) do
      def replace? = op == "replace"

      # -> the new content, or nil when this edit no longer applies to `content`.
      # `append` puts the text at the END of the file: `anchor` is a LABEL for the
      # reviewer ("## shipping_quote"), never a locator — the locator is `before`,
      # and inventing a second one would give the same edit two ways to land.
      def apply_to(content)
        return nil if content.nil?
        return "#{content.chomp}\n\n#{after}\n" unless replace?
        return nil unless content.include?(before)

        content.sub(before, after)
      end

      def to_h = { "file" => file, "op" => op, "anchor" => anchor, "before" => before,
                   "after" => after, "addresses" => addresses }
    end

    # A dropped edit and why. Kept ON the candidate rather than logged: "the model
    # proposed four things and one was stale" is exactly what an operator reviewing
    # the loop's usefulness needs, and §10 asks them to judge precisely that.
    Dropped = Data.define(:file, :op, :reason) do
      def to_h = { "file" => file, "op" => op, "reason" => reason }
    end

    Candidate = Data.define(:id, :proposer, :rationale, :edits, :dropped) do
      def empty? = edits.empty?
      def files = edits.map(&:file).uniq

      # name => new content, for the files this candidate touches. Edits to the same
      # file compose in order, so two edits to TOOLS.md both land.
      def apply(contents)
        edits.each_with_object({}) do |edit, acc|
          current = acc[edit.file] || contents[edit.file]
          applied = edit.apply_to(current)
          acc[edit.file] = applied unless applied.nil?
        end
      end

      def to_h = { "id" => id, "proposer" => proposer, "rationale" => rationale,
                   "edits" => edits.map(&:to_h), "dropped" => dropped.map(&:to_h) }
    end

    # The bounds, all config (§3.4). Defaults are deliberately small: what makes a
    # diff reviewable is that it is short, and what keeps the gate's signal readable
    # is that a run changed few things.
    DEFAULT_LIMITS = { "max_edits" => 3, "max_bytes" => 1200, "max_total_growth" => 0.15 }.freeze

    OPS = %w[replace append].freeze

    module CandidateBuilder
      module_function

      # raw:       { "proposer" =>, "rationale" =>, "edits" => [ … ] } (string keys)
      # allowlist: the agent's `refinement.files`. EMPTY MEANS NOTHING IS WRITABLE —
      #            report-only (§3.1/§3.8), so every edit drops. Not "no restriction":
      #            an unset allowlist that meant "anything" would turn a missing
      #            config into the most permissive setting there is.
      # contents:  name => current content, for staleness and growth.
      # -> Candidate (possibly empty; `empty?` never reaches the gate).
      def build(raw, allowlist:, contents:, limits: {}, id: nil)
        raw = Coercion.deep_stringify(raw.is_a?(Hash) ? raw : {})
        bounds = DEFAULT_LIMITS.merge(limits.is_a?(Hash) ? Coercion.deep_stringify(limits) : {})
        allow = Array(allowlist).map(&:to_s)

        kept = []
        dropped = []
        # Growth is measured per FILE across the whole candidate, so three edits that
        # are each under the cap cannot add up to a rewritten file.
        grown = Hash.new(0)

        Array(raw["edits"]).each do |edit|
          built, reason = validate(Coercion.deep_stringify(edit), allow, contents, bounds, grown, kept.size)
          if built
            kept << built
            grown[built.file] += built.after.to_s.bytesize - (built.replace? ? built.before.to_s.bytesize : 0)
          else
            dropped << Dropped.new(file: edit_field(edit, "file"), op: edit_field(edit, "op"), reason: reason)
          end
        end

        Candidate.new(id: (id || SecureRandom.uuid).to_s,
                      proposer: Coercion.presence(raw["proposer"]) || "operator",
                      rationale: raw["rationale"].to_s, edits: kept, dropped: dropped)
      end

      # -> [Edit, nil] | [nil, reason]. One reason per edit, in the order an operator
      # would ask: is it allowed, is it well-formed, does it still apply, is it small.
      def validate(raw, allow, contents, bounds, grown, kept_count)
        file = raw["file"].to_s
        op = raw["op"].to_s
        after = raw["after"].to_s

        return [nil, "candidate is over max_edits (#{bounds['max_edits']})"] if kept_count >= bounds["max_edits"].to_i
        return [nil, "'#{file}' is not on the refinement allowlist"] unless allow.include?(file)
        return [nil, "unknown op '#{op}' (#{OPS.join('|')})"] unless OPS.include?(op)

        current = contents[file]
        return [nil, "'#{file}' does not exist for this agent"] if current.nil?
        return [nil, "'after' is empty"] if after.strip.empty?

        if after.bytesize > bounds["max_bytes"].to_i
          return [nil, "edit is #{after.bytesize}B, over max_bytes (#{bounds['max_bytes']})"]
        end

        edit = Edit.new(file: file, op: op, anchor: Coercion.presence(raw["anchor"]),
                        before: raw["before"].to_s, after: after,
                        addresses: Array(raw["addresses"]).map(&:to_s))

        if edit.replace?
          return [nil, "'before' is empty — a replace with no anchor text is a rewrite"] if edit.before.empty?
          # STALE: the file changed since the proposal was built (or the model
          # hallucinated the text it claims to be replacing). Either way the edit
          # describes a file that does not exist, and applying it by fuzzy match is
          # how a refinement loop silently clobbers a human's edit.
          return [nil, "'before' no longer matches '#{file}' (stale or invented)"] unless current.include?(edit.before)

          if current.scan(edit.before).length > 1
            return [nil, "'before' matches '#{file}' in #{current.scan(edit.before).length} places — ambiguous"]
          end
        end

        growth = grown[file] + after.bytesize - (edit.replace? ? edit.before.bytesize : 0)
        cap = (current.bytesize * bounds["max_total_growth"].to_f).ceil
        return [nil, "would grow '#{file}' by #{growth}B, over max_total_growth (#{cap}B)"] if growth > cap

        [edit, nil]
      end

      def edit_field(edit, key)
        return nil unless edit.is_a?(Hash)

        (edit[key] || edit[key.to_sym]).to_s
      end
    end
  end
end
