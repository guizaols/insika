# frozen_string_literal: true

require "securerandom"
require "ruby_llm"
require_relative "agent_enum"

module Insika
  module Tools
    # `run_persona_eval` — a QA agent's own probe: pick an authored SIMULATED
    # persona case (Evals::GoldenStore) and run it, in-process, against the
    # case's declared target agent — the same Simulator + Judge machinery
    # `insika evals:simulate` drives over HTTP, minus the CLI and the network
    # hop (RFC-0014 PR2, the C3.1 plan).
    #
    # SAFETY is DERIVED, never a flag: the target's reachable side-effect tools
    # are computed from the live registry (Evals::EvalProfile), the same way
    # the CLI derives them. There is no swap wired here — an eval profile that
    # actually swaps a reachable side-effect tool for a fake is future work
    # (Evals::EvalProfile.registry exists for it, unused so far) — so a target
    # that has ANY reachable side-effect tool is REFUSED outright, with the
    # offending names. A read-only target needs no swap: Simulator::Safety's
    # own "side_effect_tools.empty?" branch already allows it.
    #
    # BUDGET: the persona model + judge model calls are the cost of running the
    # eval, charged to the CALLING agent's turn (never the target's — the
    # target's own turns are billed normally, through the ordinary edge
    # limiter, exactly as if a customer had sent those messages). A hard cap on
    # the calling agent skips the run — visibly, in the tool result — before a
    # cent is spent.
    class RunPersonaEval < RubyLLM::Tool
      description "Run an authored simulated-customer persona case, in-process, against " \
                  "its target agent and score the whole conversation with the configured " \
                  "judge panel. Refuses if the target exposes a tool that could write for " \
                  "real."
      param :case_id, desc: "Id of the persona case to run"

      def name = "run_persona_eval"

      # golden_store: Evals::GoldenStore — where authored persona cases live.
      # profiles:     ProfileSource — resolves both the target agent (the
      #               case's `agent:`) and the CALLING agent (turn_context, for
      #               the budget check).
      # tool_registry: the deployment's EFFECTIVE registry — what
      #               Evals::EvalProfile derives the target's side-effect tools
      #               from (the same registry a real turn resolves tools on).
      # runtime:      anything answering `#chat(message, session_id:, agent:)`
      #               (raises Insika::Error on failure) — Evals::GraphTransport's
      #               contract. In practice the DSL::Runtime the tool is wired
      #               into (its own graph, its own credentials).
      # settings_store: where the platform `utility_model` (persona) and the
      #               judge panel (`evals.judges`) are configured.
      # budget_ledger: WS2 counters — read before the run (skip on a hard cap),
      #               written after (persona + judge spend only).
      def initialize(golden_store:, profiles:, tool_registry:, runtime:, settings_store:,
                     budget_ledger: nil, event_stream: nil)
        @golden_store = golden_store
        @profiles = profiles
        @tool_registry = tool_registry
        @runtime = runtime
        @settings_store = settings_store
        @budget_ledger = budget_ledger
        @event_stream = event_stream
        super()
      end

      # Per-turn bindings, deposited by the Executor (ToolAssembly's
      # `turn_context=` seam — same as save_artifact/data-tools). Only the
      # CALLING agent's id + declared tenant are used here (the budget check);
      # never a tenant/agent the model types.
      attr_reader :turn_context

      def turn_context=(ctx)
        @turn_context = (ctx || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      # The runnable case ids, named so the model cannot guess one that does
      # not exist (the Subagent tool's lesson — see AgentEnum).
      def description
        ids = case_ids
        return super if ids.empty?

        "#{super} Cases you may run: #{ids.join(', ')}."
      end

      def params_schema
        Insika::Tools::AgentEnum.inject(super, case_ids, path: %i[case_id])
      end

      def execute(case_id:)
        golden = @golden_store.find(case_id.to_s)
        return { error: "unknown or invalid persona case '#{case_id}'" } unless golden&.simulated?

        target = @profiles[golden.agent]
        return { error: "persona case '#{case_id}' targets unknown agent '#{golden.agent}'" } unless target

        derived = Insika::Evals::EvalProfile.side_effect_tools(target, @tool_registry)
        return refuse_side_effects(golden.agent, derived) unless derived.empty?

        skip = budget_skip
        return skip if skip

        meter = []
        judge = build_judge(meter)
        return { error: "no judge configured for this case — Studio -> Settings -> Evals" } unless judge

        persona_ask = build_persona_ask(meter)
        return persona_ask if persona_ask.is_a?(Hash) # {error:}

        run_and_score(golden, derived, persona_ask, judge, meter)
      rescue Insika::Evals::Simulator::UnsafeTarget => e
        { error: e.message }
      end

      private

      def refuse_side_effects(agent, derived)
        { error: "target agent '#{agent}' exposes side-effect tool(s) (#{derived.join(', ')}) — " \
                 "run_persona_eval only runs against agents with no reachable side-effect tool " \
                 "(no swap is wired here yet)" }
      end

      def run_and_score(golden, derived, persona_ask, judge, meter)
        transport = Insika::Evals::GraphTransport.new(runtime: @runtime, event_stream: @event_stream)
        safety = Insika::Evals::Simulator::Safety.new(side_effect_tools: derived)
        simulator = Insika::Evals::Simulator.new(transport: transport, ask: persona_ask, safety: safety)

        conv = "eval-#{golden.id}-#{SecureRandom.hex(4)}" # a fresh session every run (never reused)
        run = simulator.run(persona: golden.persona, agent: golden.agent, conv: conv)
        verdict = judge.score_conversation(
          rubric: golden.rubric, transcript: run.transcript, policy: golden.policy,
          min_score: golden.min_score || Insika::Evals::Judge::DEFAULT_MIN_SCORE
        )
        account_spend(meter)

        { case: golden.id, agent: golden.agent, stop: run.stop.to_s, turns: run.turns,
          score: verdict&.score, pass: verdict&.pass, reason: verdict&.reason,
          transcript: run.transcript.map { |m| { role: m[:role], text: m[:text] } } }
      end

      # -> [String] every case this tool can run: a valid, SIMULATED (persona:)
      # golden. A scripted (turns:) case has nothing to simulate — the CLI
      # skips it too.
      def case_ids
        @golden_store.ids.select { |id| @golden_store.find(id)&.simulated? }
      end

      # settings["evals"] -> the configured judge panel, scoped to this
      # graph's own RubyLLM credentials (never the process-wide default —
      # a graph's judge spends the graph's own key) and METERED (every judge
      # call's usage lands in `meter`). nil = nobody configured (the CLI's own
      # rule: never guess a judge to spend money on).
      def build_judge(meter)
        judge, = Insika::Evals::JudgePanel.build(@settings_store.get["evals"] || {}, chat_factory: metered_factory(meter))
        judge
      end

      # The persona model — the platform `utility_model` (never a caller-chosen
      # model: the model does not get to pick what it costs to test itself),
      # metered the same way. -> callable | {error:}.
      def build_persona_ask(meter)
        model = Insika::Coercion.presence(@settings_store.get["utility_model"])
        return { error: "no persona model — set the platform utility_model (Studio -> Settings)" } if model.nil?

        metered_factory(meter).call(model, nil)
      end

      def llm_context
        @runtime.respond_to?(:llm) ? @runtime.llm : nil
      end

      # ->(model, provider) { ask } — a RubyLLM chat (this graph's own
      # credentials, temperature 0) whose every `#ask` lands its Message in
      # `sink` before handing back the text. Same shape as
      # JudgePanel.ruby_llm_ask, except it does not throw the usage away.
      def metered_factory(sink)
        lambda do |model, provider|
          chat = (llm_context || RubyLLM).chat(model: model, provider: provider, assume_model_exists: true)
                                          .with_temperature(0)
          lambda do |prompt|
            msg = chat.ask(prompt)
            sink << msg
            msg.content
          end
        end
      end

      # -> truthy (a visible skip result) when the CALLING agent's own hard
      # budget is already at/over a window cap; nil otherwise. Mirrors
      # ScheduleEngine#budget_exhausted? — a HARD cap skips rather than spends
      # (a soft one just runs; the ledger's own alert already warns).
      def budget_skip
        return nil unless @budget_ledger

        agent_id = turn_context&.dig(:agent_id)
        profile = agent_id && @profiles[agent_id]
        budget = profile&.respond_to?(:budget) ? profile.budget : nil
        return nil if budget.nil? || budget["soft"] == true

        tenant = turn_context&.dig(:command_tenant)
        window = %w[daily monthly].find do |w|
          cap = budget[w].to_i
          cap.positive? && @budget_ledger.current(tenant: tenant, agent: agent_id)[w.to_sym] >= cap
        end
        { skipped: true, reason: "budget", window: window } if window
      end

      # The turn's real billed spend for the persona + judge calls (the A4
      # rule: total + cached + cache_creation), charged to the CALLING agent —
      # never the target, whose own turns are billed normally by the edge
      # limiter, exactly like a real customer's would be.
      def account_spend(meter)
        return if @budget_ledger.nil? || meter.empty?

        tokens = meter.sum do |m|
          m.input_tokens.to_i + m.output_tokens.to_i +
            (m.respond_to?(:cached_tokens) ? m.cached_tokens.to_i : 0) +
            (m.respond_to?(:cache_creation_tokens) ? m.cache_creation_tokens.to_i : 0)
        end
        return if tokens.zero?

        @budget_ledger.add(tenant: turn_context&.dig(:command_tenant),
                          agent: turn_context&.dig(:agent_id), by: tokens)
      end
    end
  end
end
