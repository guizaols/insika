# frozen_string_literal: true

module Insika
  module Evals
    # SIMULATED USERS (RFC-0014 PR2). Two models talking: the target agent
    # (reached through the same Transport seam as the Runner) and the simulated
    # customer (a cheap model — the platform utility_model — playing a `Persona`).
    #
    # Pure over its seams, like the Runner: the Transport is injected (HttpTransport
    # for a remote deployment, GraphTransport for the own graph, A2ATransport for an
    # agent that only speaks A2A) and the persona model is an injected `ask`
    # (prompt -> raw text), so the loop is unit-testable offline.
    #
    # Termination is recorded, never guessed: the persona's `max_turns`, the persona
    # emitting `<<goal_met>>` (its goal is served) or `<<gave_up>>` (it abandons),
    # or an errored agent turn. "Gave up at turn 3" is a finding, not a detail.
    #
    # SAFETY (rule fixed in the spec): a simulated conversation must not write for
    # real. The `Safety` gate refuses the run unless the target is declared
    # `staging` or the run uses an eval profile where the agent's side-effect tools
    # are swapped for fakes — and the swap list is DERIVED from the tool registry
    # (the engine marks `side_effect` on tools; see `EvalProfile`), never
    # hand-maintained. Every run is `simulated: true`, so a report never mixes a
    # generated conversation with real traffic.
    class Simulator
      STOP_GOAL_MET = "<<goal_met>>"
      STOP_GAVE_UP = "<<gave_up>>"
      STOPS = { STOP_GOAL_MET => :goal_met, STOP_GAVE_UP => :gave_up }.freeze

      # A generated conversation. `transcript` is [{ role: "user"|"assistant",
      # text:, tools: [names] }] in order; `stop` is one of :goal_met | :gave_up |
      # :max_turns | :error; `simulated` is ALWAYS true — the flag that keeps a
      # report from mixing generated traffic with real conversations (rule D).
      SimulatedRun = Struct.new(:transcript, :stop, :turns, :error, keyword_init: true) do
        def simulated = true
        def simulated? = true

        def to_h
          { "simulated" => true, "stop" => stop.to_s, "turns" => turns, "error" => error,
            "transcript" => transcript }.compact
        end
      end

      # The target-safety gate. A run is allowed when:
      #   · `staging`         — the operator declares the target is a staging
      #                         deployment (real tools, staging data), or
      #   · the derived `side_effect_tools` is EMPTY — the agent has nothing
      #     that can write, or
      #   · `eval_profile` AND `swapped_tools` covers EVERY derived
      #     side-effect tool — the eval profile swaps them all for dry-runs.
      # Anything else is refused with the offending tool names. Refusals are loud:
      # `UnsafeTarget` is raised BEFORE a single model call.
      #
      # `side_effect_tools` is the DERIVED list (see EvalProfile) — never a
      # hand-typed claim; `swapped_tools` is what the run's eval profile declares
      # it swaps. A bare `eval_profile: true` with a known side-effect list is
      # REFUSED: an eval profile that leaves a write-capable tool unswapped is a
      # trust-me flag wearing a safety's clothes.
      Safety = Struct.new(:staging, :eval_profile, :side_effect_tools, :swapped_tools, keyword_init: true) do
        def self.staging = new(staging: true)

        # -> reason to refuse, or nil. `side_effect_tools` is the DERIVED list (the
        # target's reachable tools the registry marks `side_effect`).
        def refusal
          return nil if staging

          tools = Array(side_effect_tools).map(&:to_s).reject(&:empty?)
          return nil if tools.empty?

          if eval_profile
            swapped = Array(swapped_tools).map(&:to_s)
            uncovered = tools - swapped
            return nil if uncovered.empty?

            return "eval profile declares swapped tool(s) (#{swapped.join(', ')}) but the target " \
                   "also exposes side-effect tool(s) (#{uncovered.join(', ')}) — an eval profile " \
                   "must swap EVERY side-effect tool"
          end

          "the target agent exposes side-effect tool(s) (#{tools.join(', ')}) — a simulated " \
            "conversation could write for real. Run against staging (--staging) or against an " \
            "eval profile where these tools are swapped for fakes (--eval-profile --eval-tools ...)."
        end
      end

      # Raised before any model call when the Safety gate refuses.
      class UnsafeTarget < StandardError; end

      # transport: the target agent seam (TurnOutcome per turn, like the Runner).
      # ask:       ->(prompt) { text } — the simulated customer (the cheap model).
      # safety:    a Safety — the gate evaluated before every run.
      def initialize(transport:, ask:, safety:)
        @transport = transport
        @ask = ask
        @safety = safety
      end

      # Runs one simulated conversation. -> SimulatedRun.
      def run(persona:, agent:, conv:)
        reason = @safety.refusal
        raise UnsafeTarget, reason if reason

        transcript = []
        message = persona.opens_with
        stop = :max_turns

        1.upto(persona.max_turns) do |turn|
          transcript << { role: "user", text: message }
          outcome = @transport.turn(agent: agent, conv: conv, message: message)
          if outcome.result.error
            transcript << { role: "assistant", text: "", tools: [] }
            return SimulatedRun.new(transcript: transcript, stop: :error, turns: turn,
                                    error: outcome.result.error)
          end
          transcript << { role: "assistant", text: outcome.result.output_text,
                          tools: outcome.result.tool_names }
          break if turn == persona.max_turns # the persona's budget is spent

          reply = @ask.call(persona.prompt(transcript)).to_s
          marker, text = strip_stop(reply)
          if marker
            transcript << { role: "user", text: text } unless text.empty?
            return SimulatedRun.new(transcript: transcript, stop: marker, turns: turn)
          end
          if text.empty?
            return SimulatedRun.new(transcript: transcript, stop: :error, turns: turn,
                                    error: "the persona produced an empty message")
          end

          message = text
        end

        SimulatedRun.new(transcript: transcript, stop: stop, turns: persona.max_turns)
      end

      private

      # -> [stop_reason | nil, text_without_marker]. A trailing stop marker ends
      # the conversation; the text before it is the customer's final message.
      def strip_stop(reply)
        text = reply.strip
        STOPS.each do |marker, reason|
          return [reason, text.delete_suffix(marker).strip] if text.end_with?(marker)
        end
        [nil, text]
      end
    end

    # The DERIVED eval profile: which of an agent's reachable tools can write for
    # real, computed from the tool registry — the engine marks `side_effect` on
    # tools (a data-tool's non-GET method, the MCP ingestor's `tools/call`), so the
    # swap list is a fact of the deployment, never a hand-maintained list.
    module EvalProfile
      module_function

      # profile + registry (answers #names and #side_effect?) ->
      # [tool names] the agent can reach that are marked side-effect, sorted.
      def side_effect_tools(profile, registry)
        allowed = if profile.tools_allow.nil? then Array(registry.names)
                  else Array(profile.tools_allow).map(&:to_s)
                  end
        denied = Array(profile.tools_deny).map(&:to_s)
        (allowed - denied).select { |name| registry.side_effect?(name) }.sort
      end

      # -> bool: can a simulated run touch this agent without a staging
      # declaration (no reachable side-effect tool)?
      def safe?(profile, registry)
        side_effect_tools(profile, registry).empty?
      end

      # A registry overlay that answers the swapped names with a DRY-RUN tool and
      # delegates everything else to the base — the "side_effect -> fake" half of
      # the eval profile, derived from the base registry (nothing hand-maintained).
      # The overlay is a drop-in for the Executor's registry: same
      # entries/resolve/side_effect? surface.
      def registry(base, side_effect_tools:, dry_run: nil)
        swapped = Array(side_effect_tools).map(&:to_s)
        fake = dry_run || ->(name) { Simulator::DryRunTool.new(name) }
        OverlayRegistry.new(base: base, swapped: swapped, fake: fake)
      end
    end

    # The overlay behind `EvalProfile.registry`. Kept as a named class so the
    # constant is assigned once at load time, not inside the method.
    class EvalProfile::OverlayRegistry
      def initialize(base:, swapped:, fake:)
        @base = base
        @swapped = swapped
        @fake = fake
      end

      def names = @base.names
      def entries = @base.entries
      def side_effect?(name) = @swapped.include?(name.to_s) ? false : @base.side_effect?(name)

      def resolve(name)
        key = name.to_s
        return @fake.call(key) if @swapped.include?(key)

        @base.resolve(key)
      end
    end
  end
end

# The dry-run fake lives with the Simulator (it is its "side_effect -> fake"
# convention). It answers the same surface as a RubyLLM tool (`call`) and never
# performs the real side effect. Its result carries `dry_run: true` so a reader
# can tell a swapped call from a real one in the transcript's tool trace.
class Insika::Evals::Simulator::DryRunTool
  def initialize(name, description: nil)
    @name = name.to_s
    @description = description ||
                   "DRY-RUN of #{@name} — disabled for this simulated run, returns a canned envelope"
  end

  def name = @name
  def description = @description

  def call(args)
    { "dry_run" => true, "tool" => @name, "simulated" => true,
      "note" => "side-effect tool disabled by the eval profile — the real call was NOT performed" }
  end
end