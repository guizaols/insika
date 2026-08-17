# frozen_string_literal: true

require_relative "pack"

module Insika
  # Public Ruby DSL — the OSS "business card":
  #
  #   agent = Insika.agent("assistant") do
  #     model "deepseek-v4-flash"
  #     instructions "You are a concise, friendly assistant."
  #   end
  #   puts agent.reply("hi, what can you do?")   # one turn, in-process
  #   agent.serve                                # control UI + /v1 on :9292
  #
  # It is THIN SUGAR that GENERATES the data (a Insika::Pack), never a bypass of
  # config-over-code (COMPETITIVE-ANALYSIS). `Insika.agent { … }.to_pack`
  # is the same portable artifact the PackImporter consumes at runtime — the DSL
  # and a hand-written pack produce the SAME profile (the parity spec proves it),
  # because BOTH go through the standard import → StoredProfileSource round-trip.
  #
  # Nothing here loads ruby_llm or the HTTP server: `require "insika"` stays light.
  # The runtime (chat/serve) is pulled in lazily by Definition (dsl/runtime.rb).
  module DSL
    module_function

    # Insika.agent("id") { … } → Definition (see #agent below on the module).
    def agent(id, &block)
      Builder.new(id).build(&block)
    end

    # Insika.system { agent("a") { … }; agent("b") { … } } → System.
    def system(&block)
      SystemBuilder.new.build(&block)
    end

    # Insika.embed(backend:) { … } → System (see #embed below on the module).
    def embed(backend:, &block)
      SystemBuilder.new.build(backend: backend, &block)
    end

    # Collects several agents into ONE runtime. A single agent is a Definition;
    # more than one needs a container, because delegation (`subagents`) and any
    # multi-agent pattern only mean something when the children live in the same
    # graph. It adds no new engine path: each agent is still its own Pack,
    # imported through the standard PackImporter.
    class SystemBuilder
      def initialize
        @definitions = []
        @workflows = []
        @runtime = {}
      end

      def build(backend: nil, &block)
        instance_eval(&block) if block
        raise ArgumentError, "Insika.system needs at least one agent" if @definitions.empty?

        System.new(definitions: @definitions, workflows: @workflows, runtime: @runtime, backend: backend)
      end

      # Declares one agent — the SAME block the standalone `Insika.agent` takes.
      # Returns its Definition, so a script can keep a handle if it wants one.
      def agent(id, &block)
        definition = Builder.new(id).build(&block)
        if @definitions.any? { |d| d.id == definition.id }
          raise ArgumentError, "duplicate agent id in system: #{definition.id}"
        end

        @definitions << definition
        definition
      end

      # Declares a WORKFLOW: deterministic Ruby orchestrating agent turns, for the
      # shapes a single tool-loop should not decide on its own — chaining, routing,
      # evaluate-and-retry. It is registered in the same WorkflowRegistry a
      # deployment uses, so it gets a durable run (the run id IS a Task),
      # `:workflow_started`/`:workflow_completed` on the event stream, and — when
      # served — `GET /v1/workflows` + `POST /v1/workflows/:name`.
      #
      #   workflow "draft", input: { type: "object", required: ["topic"], … } do |input, ctx|
      #     draft = ctx.ask("writer", "Write about #{input['topic']}")
      #     ctx.ask("editor", "Tighten this:\n#{draft}")
      #   end
      #
      # `input:`/`output:` take a JSON Schema Hash (validated by the engine's
      # zero-dep validator) or any dry-schema-compatible `#call`-able. A bad input
      # is refused synchronously, with NO run created.
      def workflow(name, description: nil, input: nil, output: nil, &block)
        raise ArgumentError, "workflow '#{name}' needs a block" if block.nil?

        name = name.to_s
        raise ArgumentError, "duplicate workflow in system: #{name}" if @workflows.any? { |w| w[:name] == name }

        @workflows << { name: name, description: description,
                        input_schema: input, output_schema: output, block: block }
        name
      end

      # System-wide runtime knobs (NOT part of any pack): they configure the LLM
      # clients for every agent. A per-agent `provider` still wins for that agent;
      # this is the default and the place to put a shared key.
      def provider(name) = @runtime[:provider] = name.to_s
      def api_key(value) = @runtime[:api_key] = value.to_s
      def api_base(value) = @runtime[:api_base] = value.to_s
    end

    # Collects the declarations and emits a Insika::Pack. Declarations map 1:1 to
    # the pack manifest (AgentProfile.build attrs) + the pack's files/skills/tools —
    # so what you write is exactly the data the engine stores.
    class Builder
      def initialize(id)
        @id = id.to_s
        @config = {}
        @files = {}
        @skills = {}
        @tools = []
        # Auto-enable the allowlist policies: harmless when the allowlist is nil=all,
        # correct once you restrict tools/skills. Visible in #to_pack — no hidden magic.
        @config[:policies] = %i[tool_allowlist skill_allowlist]
        @runtime = {} # non-pack knobs (llm provider/key/base) consumed by the runtime
      end

      def build(&block)
        instance_eval(&block) if block
        Definition.new(pack: to_pack, runtime: @runtime)
      end

      # --- identity & model ------------------------------------------------
      def model(name) = @config[:model] = name.to_s

      # Provider for both the profile AND the RubyLLM configuration at run time.
      def provider(name)
        @config[:provider] = name.to_s
        @runtime[:provider] ||= name.to_s
      end

      def instructions(text) = @config[:base_prompt] = text.to_s
      alias_method :prompt, :instructions

      # An extra prompt FILE (identity fragment). Name = the file name (e.g. "SOUL.md").
      def prompt_file(name, content)
        @files[name.to_s] = content.to_s
      end

      # --- tools -----------------------------------------------------------
      # tools "a", "b"  → allowlist [names]. Not called → nil = all (parity).
      def tools(*names)
        @config[:tools_allow] = names.flatten.map(&:to_s)
      end

      def deny_tools(*names)
        @config[:tools_deny] = names.flatten.map(&:to_s)
      end

      # A DATA-DEFINED (declarative HTTP) tool — pure config-over-code. `defn` is a
      # ToolDefinition hash (name/description/parameters/binding…). Its name is
      # auto-added to the allowlist so the agent can call its own tool.
      def data_tool(defn)
        h = defn.transform_keys(&:to_s)
        @tools << h
        name = h["name"].to_s
        (@config[:tools_allow] ||= []) << name unless name.empty? || Array(@config[:tools_allow]).include?(name)
        h
      end

      # --- skills ----------------------------------------------------------
      # skill "escalate", "<full SKILL.md>"  — or —
      # skill "escalate", description: "…", instructions: "…"
      # The name is auto-added to the agent's skill allowlist.
      def skill(name, content = nil, description: nil, instructions: nil)
        n = name.to_s
        @skills[n] = normalize_skill(n, content, description, instructions)
        (@config[:skills] ||= []) << n unless @config.fetch(:skills, []).include?(n)
        n
      end

      # skills_eager — turns progressive disclosure off for THIS agent, wholly or in
      # part. The body of an eager skill is in the prompt on every turn, so its
      # activation is not a decision and cannot be missed; it is paid for on every
      # turn, so measure the bodies against `context_budget` first (a stable position
      # makes them a cacheable prefix).
      #
      #   skills_eager                       # every allowed skill
      #   skills_eager "formato", "markers"  # exactly these
      #   skills_eager false                 # none (the default)
      #
      # A LIST and not a per-skill flag because skills are shared: `escalation-to-human`
      # sits in several allowlists, and one flag on the skill would force one decision
      # onto every agent holding it.
      def skills_eager(*names)
        flat = names.flatten
        @config[:skills_eager] =
          if flat.empty? then true
          elsif flat == [true] || flat == [false] then flat.first
          else flat.map(&:to_s)
          end
      end

      # --- delegation ------------------------------------------------------
      # subagents "security", "performance" → the child agents this one MAY
      # spawn. CAPACITY field: opt-in, never inherited, and the ids
      # must be agents of the same system (`Insika.system { … }`) or already in
      # the store. Present ⇒ the engine wires `spawn_subagent`/`spawn_subagents`.
      def subagents(*ids)
        @config[:subagents] = ids.flatten.map(&:to_s)
      end

      # --- knobs -----------------------------------------------------------
      def memory(on = true) = @config[:memory] = on

      # Spend caps per calendar window (WS2): daily/monthly token budgets for
      # this agent, per (tenant, agent) when multi-tenant. HARD is the default:
      # absent `soft:` (or `soft: false`) turns the cap into a hard wall (the
      # turn fails with budget_exceeded + retry_after); `soft: true` warns once
      # per window and keeps running.
      #   budget daily: 100_000, monthly: 2_000_000, soft: false
      def budget(hash) = (@config[:budget] ||= {}).merge!(hash.transform_keys(&:to_s))

      # Provider-interaction reliability, as DATA (WS3): retries + exponential
      # backoff on transient failures, a fallback model chain (mid-turn
      # rotation), and a circuit breaker per (tenant, provider/model) that
      # fail-fasts once the window trips. `fallback`/`circuit_breaker` entries
      # are "provider/model" refs or plain model ids.
      #   reliability retries: 3, backoff: "exponential",
      #               fallback: ["gpt-4o-mini"], circuit_breaker: { after: 10, within: 60, cooldown: 300 }
      def reliability(hash)
        (@config[:reliability] ||= {}).merge!(hash.transform_keys(&:to_s))
      end

# Operator alert delivery (WS6): POST this agent's budget_warning /
      # breaker_open / delivery_failed events to the webhook as JSON.
      def alerts(hash) = (@config[:alerts] ||= {}).merge!(hash.transform_keys(&:to_s))

      # Intent routing (WS4): classify each turn's message into one route with a
      # cheap model BEFORE the ask. A Hash: route name -> description (or a Hash
      # with description/delegate/stuck/message), plus the reserved keys
      # "default" (the deterministic fallback) and "model"/"provider" (the cheap
      # classifier). The classifier prompt is generated — data only.
      #   routes "shopping" => "the customer wants to browse products",
      #          "order"    => { "description" => "asks about an existing order",
      #                          "delegate" => "order-agent" },
      #          "human"    => { "description" => "the customer asks for a person",
      #                          "stuck" => true },
      #          "default"  => "shopping", "model" => "deepseek-v4-flash"
      def routes(hash) = (@config[:routes] ||= {}).merge!(hash.transform_keys(&:to_s))

      # The agent may signal it cannot proceed (WS5): when on, the model
      # can call `signal_stuck`, which ends the turn with `outcome: :stuck` + a final
      # message + a `:turn_stuck` event. What "stuck" means is the consumer's call.
      #   stuck_signal true
      def stuck_signal(on = true) = @config[:stuck_signal] = on

      # The per-session working-state schema this agent keeps and asks for
      # (RFC-0028): a flat list of field names. [] = off (no provider output,
      # no update_briefing/set_next_step tools).
      #   briefing_fields "size", "budget", "delivery_day"
      def briefing_fields(*names)
        @config[:briefing_fields] = names.flatten.map(&:to_s)
      end

      # Generated-media output policy (WS9, saída): the media kinds this
      # agent MAY generate as turn outputs, with per-kind config. The other
      # half of the gate is the CHANNEL's: the request must declare the
      # matching capability for the tools to exist at all.
      #   outputs image: { model: "gpt-image-1", size: "1024x1024" },
      #           tts:   { model: "tts-1", voice: "alloy" }
      def outputs(hash) = (@config[:outputs] ||= {}).merge!(hash.transform_keys(&:to_s))

      # Mechanical tool-result dedupe in the replayed history
      # (no-LLM compaction, apt for bloated transcripts). CHANGES WHAT THE MODEL
      # SEES: repeated identical tool results collapse to a back-reference.
      def tool_output_compression(on = true) = @config[:tool_output_compression] = on

      # Content-safety guardrails — opt-in and configurable per agent.
      # Pure config-over-code: the hash is stored on the profile and consumed by
      # Safety::Config.from_profile. Merges, so repeated calls accumulate.
      #   guardrails input: true, output: true, strictness: "medium",
      #              moderator: "deepseek/deepseek-v4-flash",
      #              responses: { "injection" => "I can't help with that." }
      def guardrails(hash) = (@config[:guardrails] ||= {}).merge!(hash.transform_keys(&:to_s))

      # Evidence-grounding policy (RFC-0029): the pack declares how the engine
      # polices product claims against the evidence ledger. Same
      # config-over-code shape as `guardrails`; absent = off (parity).
      #   grounding mode: :flag, matcher: { sku: '\b[A-Z]{2,4}\d{4,8}\b' }
      def grounding(hash = {}) = (@config[:grounding] ||= {}).merge!(hash.transform_keys(&:to_s))

      # Refinement — how the agent's own instruction files may be
      # improved from real traffic. Same config-over-code shape as `guardrails`;
      # omitting it entirely leaves the agent report-only (writes nothing).
      #   refine mode: "propose", window: { last_sessions: 200 }, files: %w[TOOLS.md],
      #          proposers: ["deepseek/deepseek-v4-flash", "gpt-5-mini"],
      #          budget: { tokens: 200_000 }
      def refine(hash) = (@config[:refinement] ||= {}).merge!(hash.transform_keys(&:to_s))

      # Facts about THIS deployment that are not tools, so an eval
      # case can declare what it needs and be skipped where it is absent instead of
      # failing for the wrong reason.
      #   declares "promotions", "human_handoff"
      def declares(*names)
        (@config[:capabilities_declared] ||= []).concat(names.flatten.map(&:to_s))
      end

      # Which internal channels may cross to the CUSTOMER. Both off by default: the
      # answer is the answer, and the provider's reasoning (`thinking`) or the model
      # narrating its tool loop (`intermediate`) is for the Studio and the trace.
      # Each opted-in channel gets its OWN frame type at `/v1/responses` — never the
      # answer's — so a consumer that only reads the answer is unaffected either way.
      #   edge_stream thinking: true, intermediate: false
      def edge_stream(hash) = (@config[:edge_stream] ||= {}).merge!(hash.transform_keys(&:to_s))

      # LLM generation params. `param:temperature, 0.2` or `params(...)`.
      def param(key, value) = (@config[:params] ||= {})[key.to_sym] = value
      def params(hash) = (@config[:params] ||= {}).merge!(hash.transform_keys(&:to_sym))
      def temperature(value) = param(:temperature, value)
      def max_tokens(value) = param(:max_tokens, value)

      # Per-agent limits (timeouts/budgets). `limit :turn_timeout, 120` or `limits(...)`.
      def limit(key, value) = (@config[:limits] ||= {})[key.to_sym] = value
      def limits(hash) = (@config[:limits] ||= {}).merge!(hash.transform_keys(&:to_sym))

      def policies(*names) = @config[:policies] = names.flatten.map(&:to_sym)
      def metadata(hash) = (@config[:metadata] ||= {}).merge!(hash.transform_keys(&:to_s))

      # --- runtime (LLM provider) config — NOT part of the pack ------------
      # Configures RubyLLM at chat/serve time. Defaults: provider = the agent's
      # provider; key = ENV["<PROVIDER>_API_KEY"].
      def api_key(value) = @runtime[:api_key] = value.to_s
      def api_base(value) = @runtime[:api_base] = value.to_s

      # The generated portable artifact — the heart of "generates the data".
      def to_pack
        Insika::Pack.from_h(
          config: @config.merge(id: @id),
          files: @files, skills: @skills, tools: @tools
        )
      end

      private

      # Ensure the skill body is a valid SKILL.md (YAML frontmatter with `name`),
      # which is what SkillCatalog parses. Raw content with frontmatter passes
      # through untouched; a bare body / structured args get wrapped.
      def normalize_skill(name, content, description, instructions)
        return content.to_s if content.is_a?(String) && content.lstrip.start_with?("---")

        body = (instructions || content).to_s
        desc = (description || first_line(body) || name).to_s
        <<~SKILL
          ---
          name: #{name}
          description: #{desc}
          ---

          #{body}
        SKILL
      end

      def first_line(text) = text.to_s.strip.lines.first&.strip
    end
  end

  module_function

  # Top-level entry point (see Insika::DSL). Returns a Insika::DSL::Definition.
  def agent(id, &block)
    DSL.agent(id, &block)
  end

  # Several agents in one runtime — the shape every multi-agent pattern needs
  # (delegation, fan-out/fan-in, routing). Returns a Insika::DSL::System.
  def system(&block)
    DSL.system(&block)
  end

  # the front door for MOUNTING Insika into an app you already
  # have. Same block as `Insika.system`, one added obligation: the caller names
  # the store, so the graph stops discovering it from `INSIKA_DB` and two graphs
  # in one process can no longer read each other's sessions.
  #
  #   INSIKA = Insika.embed(backend: Insika::Stores::SQLite.new(path: "storage/insika.sqlite3")) do
  #     agent "support" do
  #       model "deepseek-v4-flash"
  #       instructions "…"
  #     end
  #   end
  #   # config/routes.rb — mount the /v1 transport as a value:
  #   mount Insika::Server.rack_app(INSIKA, token: ENV.fetch("INSIKA_TOKEN")), at: "/ai"
  #
  # It is a thin front door over the SAME assembly `Insika.system` uses — there is
  # one pipeline, and the parity spec holds it to that. What an embedded
  # graph owns, and what it still shares with the process, is docs/EMBEDDING.md.
  def embed(backend:, &block)
    DSL.embed(backend: backend, &block)
  end
end

require_relative "dsl/definition"
require_relative "dsl/system"
