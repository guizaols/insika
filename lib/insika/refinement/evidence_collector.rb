# frozen_string_literal: true

require "json"
require "time"

module Insika
  module Refinement
    # RFC-0013 phase A. Reads a window of an agent's real traffic and emits RANKED
    # FINDINGS — "here is what broke, how often, and in which conversations". No
    # model runs here and nothing is written to the agent: this is the evidence half
    # of the loop, and it is deliberately useful on its own.
    #
    # It reads ONLY durable data the engine already records:
    #   TaskStore       — the turn, its Command (which carries the agent) and the
    #                     executions (a failed turn keeps its error)
    #   SessionStore    — the transcript (repetition, canned safe replies)
    #   ToolTraceStore  — per-session tool calls with ok/args/result (already masked
    #                     and clipped by the store itself)
    #
    # Two signals of RFC-0013 §3.3 are NOT computed here, and that is a finding about
    # the engine rather than about an agent: guardrail decisions and edge-limit hits
    # are emitted as EVENTS and never persisted, so the only durable footprint they
    # leave is the canned safe reply in the transcript — which is exactly what the
    # `safe_reply` finding matches. Attributing one to a specific rule needs a write
    # path that does not exist yet.
    #
    # The agent of a turn comes from the Task's Command payload, not from the
    # Session: a Session does not stamp which agent produced it.
    class EvidenceCollector
      include Coercion

      DEFAULT_WINDOW      = 200   # distinct sessions, most recent first
      DEFAULT_MAX_FINDINGS = 20
      MAX_PROVENANCE      = 5     # session ids kept per finding
      SNIPPET_CHARS       = 160
      REPETITION_JACCARD  = 0.6
      REPETITION_MIN_WORDS = 3    # "oi"/"sim" repeated is not a defect

      # LEGACY FALLBACK, for transcripts written before messages carried an origin.
      #
      # A message the engine wrote itself — an injected context fragment, a delegation
      # result delivered as a new turn — is persisted with `role: user` like any
      # other, because it is what the model saw. Counting those as the customer
      # repeating themselves turned the first production run into 219 false positives,
      # every one of them the engine reading its own `<store_cep_obrigatorio>` back.
      #
      # `MessageOrigin` is the structural answer and is preferred whenever a message
      # carries it. This regex stays for everything written before that field existed
      # (the pilot's database is full of it) and for consumers that have not started
      # declaring `origin` — it is a guess, and it only ever runs on messages that
      # made no claim about themselves.
      INJECTED_FRAGMENT_RE = /\A<[a-z][a-z0-9_:.-]*>/i

      # Weight of a finding kind when ranking (count × severity).
      SEVERITY = {
        tool_error: 3, task_failed: 3, safe_reply: 2, repetition: 2, tool_unused: 1
      }.freeze

      # One defect, aggregated over the window. `key` is the stable identity used to
      # dedupe/group (and, later, for a proposal to say which finding it addresses);
      # `sessions` is provenance — ids only, capped, never content.
      Finding = Data.define(:kind, :key, :title, :count, :severity, :sessions, :detail)

      # What a run looked at, alongside what it found. `excluded` is reported rather
      # than swallowed: a window that quietly dropped half the traffic reads like a
      # clean deployment.
      Report = Data.define(:agent_id, :window, :findings, :sessions_seen, :turns_seen,
                           :excluded)

      def initialize(task_store:, session_store:, tool_trace_store:, profiles:,
                     settings_store: nil)
        @task_store = task_store
        @session_store = session_store
        @tool_trace_store = tool_trace_store
        @profiles = ProfileSource.coerce(profiles)
        @settings_store = settings_store
      end

      # -> Report. `since` (ISO8601) wins over `last_sessions` when both are given:
      # an incremental run ("what happened since the last one") is the common case.
      #
      # `exclude_sessions` drops sessions whose id starts with any of the given
      # prefixes. It defaults to NOTHING — a report must not decide on its own what
      # counts as real traffic — but a deployment that replays load tests or debug
      # conversations into the same store needs it: on the pilot, `loadtest-` sessions
      # outnumbered real ones and drowned every genuine finding.
      def collect(agent_id:, last_sessions: DEFAULT_WINDOW, since: nil,
                  max_findings: DEFAULT_MAX_FINDINGS, exclude_sessions: [])
        agent = agent_id.to_s
        profile = @profiles[agent] ||
                  (raise Insika::NotFoundError, "agent '#{agent}' not configured")

        tasks, excluded = window_tasks(agent, last_sessions: last_sessions, since: since,
                                              exclude_sessions: Array(exclude_sessions))
        session_ids = tasks.filter_map { |t| presence(t.session_id) }.uniq
        traces = session_ids.to_h { |sid| [sid, @tool_trace_store.for_session(sid)] }

        findings = [
          *tool_error_findings(traces),
          *task_failed_findings(tasks),
          *repetition_findings(session_ids),
          *safe_reply_findings(session_ids, profile),
          # An EMPTY window says nothing about a tool being unused — it says the agent
          # did not run. Without this guard every incremental run over quiet traffic
          # would report the whole tool list as "never called".
          *(tasks.empty? ? [] : tool_unused_findings(profile, traces))
        ]

        Report.new(
          agent_id: agent,
          window: since ? { "since" => since.to_s } : { "last_sessions" => last_sessions },
          findings: rank(findings).first(max_findings),
          sessions_seen: session_ids.size, turns_seen: tasks.size, excluded: excluded
        )
      end

      private

      # The agent's turns, most recent first, and how many were excluded.
      # -> [[Task], Integer]. O(n) over every task: the key is a UUID so `list` cannot
      # order by time and there is no index by agent — same trade-off
      # TaskStore#with_status already takes (one node, local SQLite).
      def window_tasks(agent, last_sessions:, since:, exclude_sessions:)
        # The id breaks the tie: `created_at` has second precision, so several turns
        # can share it and `sort_by` alone would order them arbitrarily — two runs over
        # the same data must produce the same window.
        all = @task_store.each_id
                         .filter_map { |id| @task_store.find(id) }
                         .select { |t| agent_of(t) == agent }
                         .sort_by { |t| [t.created_at.to_s, t.id] }.reverse

        kept = exclude_sessions.empty? ? all : all.reject { |t| excluded?(t, exclude_sessions) }
        excluded = all.size - kept.size

        return [kept.select { |t| t.created_at.to_s >= since.to_s }, excluded] if presence(since)

        [take_until_sessions(kept, last_sessions), excluded]
      end

      def excluded?(task, prefixes)
        sid = task.session_id.to_s
        prefixes.any? { |p| sid.start_with?(p.to_s) }
      end

      # Walks newest-first and stops once `limit` DISTINCT sessions have been seen —
      # so the window is "the last N conversations", not "the last N turns".
      def take_until_sessions(tasks, limit)
        seen = {}
        tasks.take_while do |task|
          sid = presence(task.session_id)
          seen[sid] = true if sid
          seen.size <= limit
        end
      end

      def agent_of(task) = task.command.is_a?(Hash) ? task.command.dig("payload", "agent").to_s : ""

      # --- findings ---------------------------------------------------------------

      # A tool call that came back an error. Grouped by tool + a normalized error
      # signature, so 40 instances of the same broken argument are ONE finding with
      # count 40 instead of 40 rows nobody reads.
      def tool_error_findings(traces)
        group(traces_entries(traces).reject { |_sid, e| e["ok"] }) do |_sid, entry|
          tool = entry["tool"].to_s
          [:tool_error, "tool_error:#{tool}:#{error_signature(entry['result'])}",
           "#{tool} failed: #{error_signature(entry['result'])}", nil]
        end
      end

      # A turn that died. The error is whatever the Executor recorded on the
      # execution, grouped by its normalized message.
      def task_failed_findings(tasks)
        failed = tasks.flat_map do |task|
          task.executions.filter_map do |ex|
            next if ex.error.nil?

            [presence(task.session_id), ex.error]
          end
        end
        group(failed) do |_sid, error|
          sig = signature(error_text(error))
          [:task_failed, "task_failed:#{sig}", "turn failed: #{sig}", nil]
        end
      end

      # The customer said the same thing twice in a row — the outside view of an
      # instruction the agent is not following. Heuristic on purpose (token overlap,
      # no model call); the snippet is PII-redacted.
      def repetition_findings(session_ids)
        hits = session_ids.flat_map do |sid|
          repeated_pairs(user_messages(sid)).map { |text| [sid, text] }
        end
        group(hits) do |_sid, text|
          [:repetition, "repetition", "customer repeated themselves", snippet(text)]
        end
      end

      # A canned safe reply reached the customer: a guardrail block or an edge limit.
      # Those decisions are events, not records (see the class comment), so the reply
      # text IS the evidence.
      #
      # This is the one finding that reads the engine's OWN replies, so it looks at
      # every assistant-role message rather than the agent's (`assistant_messages`
      # deliberately excludes them). Two ways to recognise one, and the first is now
      # exact: a reply the engine wrote SAYS so (`origin: engine`). The canned-text
      # match stays for transcripts written before that — and for a text match the
      # strings are emitted verbatim, so it is an exact compare, never a prefix.
      def safe_reply_findings(session_ids, profile)
        canned = canned_replies(profile)

        hits = session_ids.flat_map do |sid|
          messages(sid)
            .select { |m| m["role"].to_s == "assistant" }
            .select { |m| MessageOrigin.origin_of(m) == MessageOrigin::ENGINE || canned.include?(m["content"].to_s.strip) }
            .map { |m| [sid, m["content"].to_s] }
        end
        group(hits) do |_sid, text|
          [:safe_reply, "safe_reply", "a canned safe reply was served instead of an answer",
           snippet(text)]
        end
      end

      # A tool the agent is allowed to use and never used in the whole window —
      # either the prompt does not mention it or it answers from memory instead.
      # Skipped when `tools_allow` is nil (= every tool; nothing to compare against).
      def tool_unused_findings(profile, traces)
        allowed = profile.tools_allow
        return [] if allowed.nil?

        used = traces_entries(traces).map { |_sid, e| e["tool"].to_s }.uniq
        (Array(allowed).map(&:to_s) - used).sort.map do |tool|
          Finding.new(kind: :tool_unused, key: "tool_unused:#{tool}",
                      title: "#{tool} was never called in this window",
                      count: 1, severity: SEVERITY[:tool_unused], sessions: [], detail: nil)
        end
      end

      # --- helpers ----------------------------------------------------------------

      def traces_entries(traces)
        traces.flat_map { |sid, entries| Array(entries).map { |e| [sid, e] } }
      end

      # [[session_id, item], …] -> [Finding] aggregated by the key the block returns.
      # The block gets (session_id, item) and returns [kind, key, title, detail].
      def group(pairs)
        pairs.each_with_object({}) do |(sid, item), acc|
          kind, key, title, detail = yield(sid, item)
          f = acc[key] ||= { kind: kind, key: key, title: title, detail: detail, sessions: [], count: 0 }
          f[:count] += 1
          f[:sessions] << sid if sid && !f[:sessions].include?(sid)
        end.values.map do |f|
          Finding.new(kind: f[:kind], key: f[:key], title: f[:title], count: f[:count],
                      severity: SEVERITY.fetch(f[:kind], 1),
                      sessions: f[:sessions].first(MAX_PROVENANCE), detail: f[:detail])
        end
      end

      # count × severity, then a stable tiebreak so two runs over the same window
      # produce the same report.
      def rank(findings)
        findings.sort_by { |f| [-(f.count * f.severity), f.kind.to_s, f.key] }
      end

      def messages(session_id) = Array(@session_store.find(session_id)&.messages)

      # What the CUSTOMER actually said. A message that DECLARES its origin is taken
      # at its word; one that declares nothing falls back to the tag heuristic, which
      # is all a pre-origin transcript offers.
      def user_messages(session_id)
        messages(session_id)
          .select { |m| MessageOrigin.customer?(m) }
          .map { |m| m["content"].to_s }
          .reject { |text| INJECTED_FRAGMENT_RE.match?(text.lstrip) }
      end

      # What the AGENT actually replied — not a guardrail's canned safe reply, and not
      # a human operator's typing in an imported transcript. Both are `role: assistant`
      # and neither is the model, so scoring them as the agent's work is wrong in both
      # directions: it flags text no model produced, and it credits the model with a
      # human's rescue.
      def assistant_messages(session_id)
        messages(session_id).select { |m| MessageOrigin.agent?(m) }.map { |m| m["content"].to_s }
      end

      # The second element of every consecutive pair that overlaps past the threshold.
      def repeated_pairs(texts)
        texts.each_cons(2).filter_map do |a, b|
          b if similar?(a, b)
        end
      end

      def similar?(first, second)
        a = words(first)
        b = words(second)
        return false if a.size < REPETITION_MIN_WORDS || b.size < REPETITION_MIN_WORDS

        union = (a | b).size
        union.positive? && ((a & b).size.to_f / union) >= REPETITION_JACCARD
      end

      def words(text) = text.to_s.downcase.scan(/[[:alnum:]]+/).uniq

      # Every reply the deployment may emit INSTEAD of a real answer: the RFC-0009
      # defaults, the agent's own overrides, and the edge limiter's reply (per-agent
      # first, then the platform setting).
      def canned_replies(profile)
        agent_overrides = (profile.guardrails || {})["responses"]
        [
          *Insika::Safety::SafeResponses::DEFAULTS.values,
          *Array(agent_overrides.is_a?(Hash) ? agent_overrides.values : nil),
          (profile.limits || {})[:limit_response],
          @settings_store&.get&.dig("edge", "limit_response")
        ].filter_map { |t| presence(t)&.strip }.uniq
      end

      # ToolTraceStore clips `result` to a String (JSON text when it was structured),
      # so the error has to be dug back out of it.
      def error_signature(result)
        parsed = begin
          JSON.parse(result.to_s)
        rescue StandardError
          nil
        end
        signature(parsed.is_a?(Hash) ? error_text(parsed) : result)
      end

      def error_text(error)
        return error["error"] || error["message"] || error.to_s if error.is_a?(Hash)

        error.to_s
      end

      # Groups variants of the same failure: collapse whitespace, blank out numbers
      # and ids (a "product 4711 not found" is the same defect as "product 4712"),
      # then cap the length.
      def signature(text)
        s = text.to_s.gsub(/\s+/, " ").strip
        s = s.gsub(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i, "<id>").gsub(/\d+/, "<n>")
        s = "(no message)" if s.empty?
        s.length > 80 ? "#{s[0, 80]}…" : s
      end

      # Redacted, capped excerpt — a report is read by an operator, so it may carry
      # customer words, but never a CPF, a phone number or a token.
      def snippet(text)
        redacted, = Insika::Safety::Detectors.redact(text.to_s.gsub(/\s+/, " ").strip)
        redacted.length > SNIPPET_CHARS ? "#{redacted[0, SNIPPET_CHARS]}…" : redacted
      end
    end
  end
end
