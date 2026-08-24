# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Absorbs SystemPrompt + SOUL.md. Identity is
      # PINNED, priority 100 — never cut. required?: an agent without identity is
      # a WRONG agent, not a degraded one. prompt_refs: priority 90 pinned
      # fragments, from the PromptCatalog (catalog defaults to nil).
      #
      # PER-AGENT identity, from `profile.prompt_files`/`base_prompt` only — an
      # agent that declares neither has no identity here, and there is no
      # deployment-wide fallback file to borrow one from. A shared fallback
      # (a prior design: an agent without prompt_files silently inherited a
      # wiring-level default) is exactly how a real deployment answered as the
      # WRONG business: a `copilot` data agent provisioned without its own
      # identity inherited the deployment's demo persona ("Bia, Pizzaria do
      # Zé") byte for byte, confirmed live. An agent never wears another
      # agent's identity — `@base`/`system_files` stay legitimate (the same
      # generic content for every agent, never one agent's specific persona).
      class Prompt < ContextProvider
        # Engine-owned execution discipline, appended AFTER the agent's identity.
        # The one behavior every reference harness bakes into its base prompt
        # (OpenClaw's "Execution Bias") and this engine was missing: a weak tool
        # result read as final. A constant — byte-identical every turn, so
        # prompt_caching pays ONE write on the deploy that introduces it, never
        # per turn. Opt-out per profile (`tool_persistence false`), the single
        # default-ON profile flag: the proven-good behavior is the default, the
        # exception is the thing an operator declares.
        TOOL_PERSISTENCE = "## Tool discipline\n" \
          "- Weak or empty tool result: try again with a different approach — rephrase the " \
          "query, use a synonym or broader term, drop a secondary filter — before telling " \
          "the user you found nothing. Do not narrate the retries. Then conclude.\n" \
          "- Tool error: read the error, fix the arguments or try another path; never " \
          "repeat the exact same call.\n" \
          "- A URL in a tool result (e.g. a `url` field): quote it byte-for-byte. Never " \
          "construct, guess, or rewrite the domain, host, or path."

        def initialize(base: "", catalog: nil, agent_files: nil, system_files: nil)
          @base = base
          @catalog = catalog
          @agent_files = agent_files
          @system_files = system_files
        end

        def required? = true
        # identity (config/agent-file derived — already pinned).
        def layer = :identity

        def call(request)
          identity = build_identity(request.profile)
          if identity.empty?
            raise ContextError.new(
              "agent '#{request.profile&.id}' has no identity of its own (no base_prompt, " \
              "no prompt_files) — refusing to run rather than answer with no identity or " \
              "another agent's",
              provider: id
            )
          end

          fragments = [ContextFragment.build(content: identity, placement: :system,
                                             priority: Context::Priority::IDENTITY, source: id, pinned: true)]
          fragments.concat(ref_fragments(request.profile))
          fragments
        end

        private

        # Migrates the SystemPrompt#build concatenation INTACT (without skills_block).
        # A SINGLE fragment preserves the internal base->files order (sorting
        # acts only BETWEEN fragments) and guarantees byte-for-byte parity.
        #
        # profile.prompt_files: each source resolves via AgentFileStore (per
        # agent) OR File.read (on-disk path) — in that order. No other agent's
        # files are ever read for this one; there is no wiring-level fallback.
        def build_identity(profile)
          parts = [@base]
          parts.concat(system_parts) # global system files, for EVERY agent
          # The agent's OWN inline identity (`base_prompt` — what the DSL's
          # `instructions` and a pack's manifest set). It was stored, round-tripped
          # and advertised on the A2A agent card while never reaching the model:
          # every root wires `base: ""`, so an agent whose identity was inline had
          # NO identity at all, and a chatty model answered plausibly enough to hide
          # it. Additive to prompt_files, not exclusive: an agent may carry both.
          parts << profile&.base_prompt.to_s
          Array(profile&.prompt_files).each { |src| parts << read_source(profile&.id, src.to_s) }
          identity = parts.reject { |p| p.nil? || p.strip.empty? }.join("\n\n")
          # Discipline rides an EXISTING identity, never substitutes one: an
          # empty identity here is fatal (`call` raises), not silently patched
          # with the engine's own boilerplate.
          return identity if identity.empty? || !tool_persistence?(profile)

          "#{identity}\n\n#{TOOL_PERSISTENCE}"
        end

        # nil/absent/true = ON (the engine default); only an explicit `false`
        # turns it off. Defensive respond_to?: a minimal profile stub reads ON.
        def tool_persistence?(profile)
          !(profile.respond_to?(:tool_persistence) && profile.tool_persistence == false)
        end

        # GLOBAL system files: apply to every agent,
        # injected BEFORE the individual identity. Empty/absent store -> [] ->
        # a prompt byte-for-byte identical to before (the injection only exists if
        # the operator authored something). Lexicographic order (SystemFileStore#list).
        def system_parts
          return [] unless @system_files

          @system_files.list.map { |name| @system_files.read(name).to_s }
        end

        # Per-agent store first, disk second (compat/seed).
        def read_source(agent_id, src)
          stored = agent_id && @agent_files&.read(agent_id, src)
          return stored if stored
          return File.read(src, encoding: "UTF-8") if File.exist?(src)

          ""
        end

        def ref_fragments(profile)
          refs = Array(profile.prompt_refs)
          return [] if refs.empty?

          refs.map do |name|
            entry = @catalog&.find(name.to_s)
            unless entry
              raise ContextError.new("prompt_ref '#{name}' not found in the Prompt Catalog",
                                     provider: id)
            end

            ContextFragment.build(content: entry.body, placement: :system,
                                  priority: Context::Priority::PROMPT_REF, source: id, pinned: true)
          end
        end
      end
    end
  end
end
