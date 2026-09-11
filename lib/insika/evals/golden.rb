# frozen_string_literal: true

require "yaml"

# Evals — the quality harness. It lives in `lib/` so the engine itself can
# call it (the refinement gate of needs to score a candidate agent, and a
# second copy of the judge would be the worst possible outcome), but it stays a
# CLIENT: it reaches a running deployment over HTTP through `HttpTransport` and never
# reads a store directly. `evals/run.rb` is a thin CLI over this module.
module Insika
  module Evals
    # A curated behavior case, loaded from a data file (evals/golden/<agent>/*.yml).
    # Data, not code — same spirit as tools-as-data. See evals/README.md for the format.
    #
    # A case is ONE of two shapes: `turns:` (a scripted replay) or
    # `persona:` (a conversation the Simulator GENERATES). A persona
    # case is `simulated?` — the replay Runner skips it, and the Simulator drives it.
    #
    # `tenant` (C3.1): which tenant authored this case — "platform" (the
    # single-tenant default, like `save_artifact`'s own binding_tenant) unless the
    # case declares one. `run_persona_eval` uses it to keep a QA agent from ever
    # running (or even seeing) another tenant's persona case in the same store.
    #
    # `state`: the snapshot the conversation starts from — evidence ids, memory
    # facts and notes, prior history, briefing fields — loaded into the session
    # BEFORE turn 1. It is how a case tests "the customer already saw three products
    # and says 'add the second one'" without replaying the search turn: no dependence
    # on the model's first answer, one turn cheaper, and a messy state (a
    # contradiction from six turns ago) becomes reproducible. {} = the case starts
    # empty, as every case did before the key existed.
    Golden = Struct.new(:id, :agent, :turns, :expect, :requires, :reference, :source, :persona, :tenant,
                        :state, :store_state, keyword_init: true) do
      # The user messages to replay, in order. Empty for a persona case: a generated
      # conversation has no scripted turns.
      def user_turns = turns.map { |t| t["user"] }

      # The simulated customer. nil for a scripted case.
      def simulated? = !persona.nil?

      def opens_with = persona ? persona.opens_with : user_turns.first

      # Tool refs the case expects; a trailing "?" marks OPTIONAL (never fails).
      # -> [{ name:, optional: }]
      def tools_called
        Array(expect["tools_called"]).map do |ref|
          s = ref.to_s
          optional = s.end_with?("?")
          { name: optional ? s[0..-2] : s, optional: optional }
        end
      end

      # The tools turn `i` (0-based) must call, same `name?` optional marker as above.
      # [] for a turn that pins nothing.
      def turn_tools_called(i)
        Array(turns.dig(i, "tools_called")).map do |ref|
          s = ref.to_s
          optional = s.end_with?("?")
          { name: optional ? s[0..-2] : s, optional: optional }
        end
      end

      # Names of the negative assertions to run (e.g. "pii_leak", "tool_error").
      def must_not = Array(expect["must_not"]).map(&:to_s)

      # `claims:` — tool name => the words a reply uses to say it did that (a regex
      # source, matched case-insensitively). What `must_not: phantom_action` reads.
      def claims = (expect["claims"] || {}).transform_keys(&:to_s)

      # The graders over the turn's CALLS and its published REPLY — each optional,
      # each deterministic. Every positive has a negative: `never_calls` pins what a
      # correct turn does NOT do, which `tools_called` alone can never say.
      def never_calls = Array(expect["never_calls"]).map(&:to_s)
      def calls_one_of = Array(expect["calls_one_of"]).map(&:to_s)
      def first_tool = GoldenLoader.presence(expect["first_tool"])
      def max_tool_calls = expect["max_tool_calls"]
      def reply_includes = Array(expect["reply_includes"]).map(&:to_s)
      def reply_omits = Array(expect["reply_omits"]).map(&:to_s)
      # "tool:gate" pairs that must appear among the turn's BLOCKED calls.
      def blocked_gates = Array(expect["blocked_gates"]).map(&:to_s)
      # UI components a presentation tool must have shown (`insika.ui` frames with
      # at least one card), and its negative: `no_ui: true` pins a turn that shows
      # nothing.
      def ui_components = Array(expect["ui_components"]).map(&:to_s)
      def no_ui? = expect["no_ui"] == true

      def state = self[:state] || {}
      def seeded? = !state.empty?

      # What the STORE must look like after the turn — the half of a commerce case
      # no reply can prove. `records` are rows that must be there, `count` the exact
      # size of a collection (a duplicated order fails it), `absent` rows that must
      # not exist. Read after the last turn by a store reader the runner is given;
      # {} = the case says nothing about the store, as every case did before.
      def store_state = self[:store_state] || {}
      def store_state? = !store_state.empty?

      # The collections this case talks about — what the reader is asked for, and
      # nothing else: a bench task about orders should not pull the catalogue.
      def store_collections
        (Array(store_state["records"]&.keys) + Array(store_state["count"]&.keys) +
          Array(store_state["absent"]&.keys)).map(&:to_s).uniq
      end

      # How much the agent should ask before acting. nil = the store
      # has no opinion and only the rubric decides.
      def policy = policy_pair.first

      # What the store set the policy TO. The engine ships the mechanism (count the
      # questions); the number is the store's, because "one question per reply" is a
      # tolerance, not a law — a greeting that says "tudo bem?" spends one on
      # courtesy in half the languages a store sells in.
      def policy_options = policy_pair.last

      # `policy: ask_once` and `policy: { ask_once: { max: 2 } }` are the same
      # declaration with and without a number. -> [name, options]
      def policy_pair
        value = expect["policy"]
        return [GoldenLoader.presence(value), {}] unless value.is_a?(Hash)

        name, options = value.first
        [GoldenLoader.presence(name), (options || {}).transform_keys(&:to_s)]
      end

      # What the DEPLOYMENT must have for this case to mean anything.
      # Empty = runs everywhere.
      def required_tools = Array(requires["tools"]).map(&:to_s)
      def required_capabilities = Array(requires["capabilities"]).map(&:to_s)
      def requirements? = !(required_tools + required_capabilities).empty?

      # THE INCUMBENT'S CONVERSATION for the same opening — the other
      # half of a pairwise comparison. Data in the case, not a store read: the eval is
      # a client, and a pair that lives in one reviewable file cannot go stale against
      # a database nobody looked at.
      def reference_messages = Array(reference["messages"])
      def reference_source = GoldenLoader.presence(reference["source"])
      def reference? = !reference_messages.empty?

      # Did a PERSON type part of the reference half? After a handoff the operator's
      # words are stored as `role: assistant`, and comparing a model to a human
      # and calling it a win is a lie in both directions — so the pair is LABELLED and
      # the report never prints the outcome without it.
      def human_assisted?
        reference_messages.any? { |m| MessageOrigin.origin_of(m) == MessageOrigin::OPERATOR }
      end

      # LLM-judge rubric + threshold (consumed in — deferred here).
      def rubric = expect["rubric"]
      def min_score = expect["min_score"]
    end

    # Loads + validates golden files. Fails LOUD on a malformed case — a silently
    # dropped golden is a hole in the safety net.
    module GoldenLoader
      class InvalidGolden < StandardError; end

      module_function

      # Loads every *.yml/*.yaml under `dir` (recursive), sorted by path for a stable
      # run order. -> [Golden].
      def load_dir(dir)
        Dir.glob(File.join(dir, "**", "*.{yml,yaml}")).sort.map { |f| load_file(f) }
      end

      def load_file(path)
        raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
        build(raw, source: path)
      rescue Psych::SyntaxError => e
        raise InvalidGolden, "#{path}: invalid YAML — #{e.message}"
      end

      # hash (string keys) -> validated Golden. `source` is only for error messages.
      def build(raw, source: "(inline)")
        raise InvalidGolden, "#{source}: golden must be a mapping" unless raw.is_a?(Hash)

        id = presence(raw["id"]) || (raise InvalidGolden, "#{source}: 'id' is required")
        agent = presence(raw["agent"]) || (raise InvalidGolden, "#{source}: 'agent' is required (case '#{id}')")
        persona = normalize_persona(raw["persona"], id: id, source: source)
        if persona && !raw["turns"].nil?
          raise InvalidGolden, "#{source}: a case is ONE shape — 'turns' or 'persona', not both (case '#{id}')"
        end

        turns = persona ? [] : normalize_turns(raw["turns"], id: id, source: source)
        expect = raw["expect"] || {}
        raise InvalidGolden, "#{source}: 'expect' must be a mapping (case '#{id}')" unless expect.is_a?(Hash)

        validate_policy!(expect["policy"], id: id, source: source)
        validate_graders!(expect, id: id, source: source)
        state = normalize_state(raw["state"], id: id, source: source)
        store_state = normalize_store_state(raw["store_state"], id: id, source: source)
        requires = raw["requires"] || {}
        unless requires.is_a?(Hash)
          raise InvalidGolden, "#{source}: 'requires' must be a mapping (case '#{id}')"
        end

        reference = normalize_reference(raw["reference"], id: id, source: source)
        tenant = presence(raw["tenant"]) || "platform"

        Golden.new(id: id, agent: agent, turns: turns, expect: expect,
                   requires: requires, reference: reference, source: source, persona: persona,
                   tenant: tenant, state: state, store_state: store_state)
      end

      # `persona:` is the alternative shape to `turns:`: the
      # conversation is GENERATED, not replayed. Malformed is REFUSED — a persona
      # without `knows` or `max_turns` would simulate nothing. The PersonaLoader
      # already prefixes its messages with the source path; the case id is added
      # ONCE here (the loader is shared by the persona-file CLI, which has no case
      # shape).
      def normalize_persona(raw, id:, source:)
        return nil if raw.nil?

        PersonaLoader.build(raw, source: source)
      rescue PersonaLoader::InvalidPersona => e
        raise InvalidGolden, "#{e.message} (case '#{id}')"
      end

      # reference: { "source" => String?, "messages" => [{ "role" =>, "text" =>,
      # "origin" => }] }. Absent -> {}, and the case simply has nothing to compare
      # against. Malformed is REFUSED: a reference that half-loads would produce a
      # pairwise verdict about a transcript nobody wrote.
      def normalize_reference(raw, id:, source:)
        return {} if raw.nil?
        raise InvalidGolden, "#{source}: 'reference' must be a mapping (case '#{id}')" unless raw.is_a?(Hash)

        messages = raw["messages"]
        unless messages.is_a?(Array) && !messages.empty?
          raise InvalidGolden, "#{source}: reference needs a non-empty 'messages' array (case '#{id}')"
        end

        { "source" => presence(raw["source"]),
          "messages" => messages.each_with_index.map { |m, i| reference_message(m, i, id: id, source: source) } }.compact
      end

      def reference_message(raw, index, id:, source:)
        where = "#{source}: reference.messages[#{index}] (case '#{id}')"
        raise InvalidGolden, "#{where} must be a mapping" unless raw.is_a?(Hash)

        role = presence(raw["role"])
        raise InvalidGolden, "#{where} needs a 'role' of user or assistant" unless %w[user assistant].include?(role)

        text = presence(raw["text"]) || (raise InvalidGolden, "#{where} needs a non-empty 'text'")
        # The SAME closed vocabulary the engine stamps. A typo'd marker would
        # read as "absent" downstream, which is how a human turn gets scored as the
        # incumbent's model.
        origin = begin
          MessageOrigin.parse!(raw["origin"])
        rescue Insika::ValidationError => e
          raise InvalidGolden, "#{where}: #{e.message}"
        end
        { "role" => role, "text" => text }.merge(origin ? { "origin" => origin } : {})
      end

      STATE_KEYS = %w[evidence memory history briefing].freeze

      # state: the snapshot a case starts from. Absent -> {}. Only the four known
      # keys, each in its own shape — a typo'd key (`evidences:`) would seed nothing
      # and the case would go on passing against the wrong precondition. Refused at
      # LOAD, not at seed time: a case that half-seeds is a hole in the net.
      def normalize_state(raw, id:, source:)
        return {} if raw.nil?

        where = "#{source}: state (case '#{id}')"
        raise InvalidGolden, "#{where} must be a mapping" unless raw.is_a?(Hash)

        unknown = raw.keys.map(&:to_s) - STATE_KEYS
        unless unknown.empty?
          raise InvalidGolden, "#{where}: unknown key(s) #{unknown.join(', ')} — known: #{STATE_KEYS.join(', ')}"
        end

        state = raw.compact
        mapping_with!(state["evidence"], "ids", Array, "#{where}.evidence")
        mapping_with!(state["memory"], "facts", Hash, "#{where}.memory")
        mapping_with!(state["memory"], "notes", Array, "#{where}.memory")
        mapping_with!(state["briefing"], "fields", Hash, "#{where}.briefing")
        history = state["history"]
        unless history.nil? || (history.is_a?(Array) && history.all? { |m| history_message?(m) })
          raise InvalidGolden, "#{where}.history must be [{ role: user|assistant, content: '…' }]"
        end

        state
      end

      STORE_STATE_KEYS = %w[records count absent].freeze

      # store_state: what the store must look like AFTER the turn, graded by code
      # against a snapshot the runner reads. Three keys, each a mapping keyed by
      # collection: `records` (rows that must exist), `count` (the exact size of a
      # collection) and `absent` (rows that must not exist). A closed vocabulary on
      # purpose — a case that wrote `orders:` at the top level would grade nothing
      # and pass, which is the failure this key exists to catch.
      def normalize_store_state(raw, id:, source:)
        return {} if raw.nil?

        where = "#{source}: store_state (case '#{id}')"
        raise InvalidGolden, "#{where} must be a mapping" unless raw.is_a?(Hash)

        unknown = raw.keys.map(&:to_s) - STORE_STATE_KEYS
        unless unknown.empty?
          raise InvalidGolden, "#{where}: unknown key(s) #{unknown.join(', ')} — " \
                               "known: #{STORE_STATE_KEYS.join(', ')}"
        end

        state = raw.compact
        rows_by_collection!(state["records"], "#{where}.records")
        rows_by_collection!(state["absent"], "#{where}.absent")
        counts!(state["count"], "#{where}.count")
        state
      end

      def rows_by_collection!(value, where)
        return if value.nil?
        raise InvalidGolden, "#{where} must be a mapping of collection -> rows" unless value.is_a?(Hash)

        value.each do |collection, rows|
          next if rows.is_a?(Array) && !rows.empty? && rows.all?(Hash)

          raise InvalidGolden, "#{where}.#{collection} must be a non-empty list of mappings"
        end
      end

      def counts!(value, where)
        return if value.nil?
        raise InvalidGolden, "#{where} must be a mapping of collection -> integer" unless value.is_a?(Hash)

        value.each do |collection, n|
          next if n.is_a?(Integer) && n >= 0

          raise InvalidGolden, "#{where}.#{collection} must be a non-negative integer (got #{n.inspect})"
        end
      end

      def mapping_with!(value, key, type, where)
        return if value.nil?
        raise InvalidGolden, "#{where} must be a mapping" unless value.is_a?(Hash)
        return if value[key].nil? || value[key].is_a?(type)

        raise InvalidGolden, "#{where}.#{key} must be #{type == Array ? 'a list' : 'a mapping'}"
      end

      def history_message?(message)
        message.is_a?(Hash) && %w[user assistant].include?(message["role"].to_s) &&
          !presence(message["content"]).nil?
      end

      # The graders with a shape to get wrong: a non-integer `max_tool_calls` would
      # compare against nil and pass; a `blocked_gates` entry without its gate would
      # never match anything and pass. Refused at load, like `policy`.
      def validate_graders!(expect, id:, source:)
        max = expect["max_tool_calls"]
        unless max.nil? || (max.is_a?(Integer) && max >= 0)
          raise InvalidGolden, "#{source}: max_tool_calls must be a non-negative integer (case '#{id}')"
        end

        Array(expect["blocked_gates"]).each do |pair|
          next if pair.to_s.match?(/\A[^:\s]+:[^:\s]+\z/)

          raise InvalidGolden, "#{source}: blocked_gates entries are 'tool:gate' (got #{pair.inspect}, case '#{id}')"
        end

        validate_claims!(expect, id: id, source: source)
      end

      # A phantom-action check with no words to look for would pass everything, and a
      # pattern that does not compile would fail every cell at grading time instead of
      # the one author at load time.
      def validate_claims!(expect, id:, source:)
        claims = expect["claims"]
        phantom = Array(expect["must_not"]).map(&:to_s).include?("phantom_action")
        if phantom && !(claims.is_a?(Hash) && !claims.empty?)
          raise InvalidGolden, "#{source}: must_not: phantom_action needs a non-empty 'claims:' map (case '#{id}')"
        end
        return if claims.nil?

        raise InvalidGolden, "#{source}: 'claims' must be a map of tool => pattern (case '#{id}')" unless claims.is_a?(Hash)

        claims.each do |tool, pattern|
          Regexp.new(pattern.to_s)
        rescue RegexpError => e
          raise InvalidGolden, "#{source}: claims.#{tool} is not a valid pattern — #{e.message} (case '#{id}')"
        end
      end

      # A typo'd policy must not silently mean "no policy" — the case would go on
      # passing while the rule it was written for stopped being checked. The
      # `Assertions` constant is resolved at CALL time (this file loads first, and
      # assertions.rb touches `Safety::Detectors` at load time).
      def validate_policy!(value, id:, source:)
        if value.is_a?(Hash)
          raise InvalidGolden, "#{source}: policy takes ONE name (case '#{id}')" unless value.size == 1

          name, options = value.first
          unless options.nil? || options.is_a?(Hash)
            raise InvalidGolden, "#{source}: policy #{name.inspect} options must be a map (case '#{id}')"
          end

          value = name
        end
        name = presence(value)
        return if name.nil? || Assertions::POLICIES.key?(name)

        raise InvalidGolden, "#{source}: unknown policy #{name.inspect} (case '#{id}') — " \
                             "known: #{Assertions::POLICIES.keys.join(', ')}"
      end

      # turns: a non-empty array of { "user" => String }. Rejects anything else so a
      # typo (e.g. `users:`) surfaces at load time, not as an empty replay.
      #
      # A turn may also carry `tools_called: [names]` — the calls THAT turn must make.
      # The case-level `tools_called` reads the last turn only, and the bench found a
      # reply that said "adicionado ao carrinho" on turn one without ever calling
      # add_to_cart, then recovered on turn two so the final store looked right.
      def normalize_turns(turns, id:, source:)
        unless turns.is_a?(Array) && !turns.empty?
          raise InvalidGolden, "#{source}: 'turns' must be a non-empty array (case '#{id}')"
        end

        turns.each_with_index.map do |t, i|
          user = t.is_a?(Hash) ? presence(t["user"]) : nil
          user || (raise InvalidGolden, "#{source}: turns[#{i}] needs a non-empty 'user' (case '#{id}')")
          tools = t["tools_called"]
          unless tools.nil? || (tools.is_a?(Array) && tools.all? { |n| presence(n) })
            raise InvalidGolden, "#{source}: turns[#{i}].tools_called must be a list of tool names (case '#{id}')"
          end

          tools.nil? ? { "user" => user } : { "user" => user, "tools_called" => tools.map(&:to_s) }
        end
      end

      def presence(v)
        s = v.to_s.strip
        s.empty? ? nil : s
      end
    end
  end
end
