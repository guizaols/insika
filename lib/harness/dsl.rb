# frozen_string_literal: true

require_relative "pack"

module Harness
  # Public Ruby DSL (item 36 / §13.3) — the OSS "business card":
  #
  #   agent = Harness.agent("assistant") do
  #     model "deepseek-chat"
  #     instructions "You are a concise, friendly assistant."
  #   end
  #   puts agent.reply("hi, what can you do?")   # one turn, in-process
  #   agent.serve                                # control UI + /v1 on :9292
  #
  # It is THIN SUGAR that GENERATES the data (a Harness::Pack), never a bypass of
  # config-over-code (COMPETITIVE-ANALYSIS §4.1). `Harness.agent { … }.to_pack`
  # is the same portable artifact the PackImporter consumes at runtime — the DSL
  # and a hand-written pack produce the SAME profile (the parity spec proves it),
  # because BOTH go through the standard import → StoredProfileSource round-trip.
  #
  # Nothing here loads ruby_llm or the HTTP server: `require "harness"` stays light.
  # The runtime (chat/serve) is pulled in lazily by Definition (dsl/runtime.rb).
  module DSL
    module_function

    # Harness.agent("id") { … } → Definition (see #agent below on the module).
    def agent(id, &block)
      Builder.new(id).build(&block)
    end

    # Collects the declarations and emits a Harness::Pack. Declarations map 1:1 to
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
      # auto-added to the allowlist so the agent can call its own tool (NF2).
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

      # --- knobs -----------------------------------------------------------
      def memory(on = true) = @config[:memory] = on

      # Content-safety guardrails (RFC-0009) — opt-in and configurable per agent.
      # Pure config-over-code: the hash is stored on the profile and consumed by
      # Safety::Config.from_profile. Merges, so repeated calls accumulate.
      #   guardrails input: true, output: true, strictness: "medium",
      #              moderator: "deepseek/deepseek-chat",
      #              responses: { "injection" => "I can't help with that." }
      def guardrails(hash) = (@config[:guardrails] ||= {}).merge!(hash.transform_keys(&:to_s))

      # LLM generation params (v2, §10). `param :temperature, 0.2` or `params(...)`.
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
        Harness::Pack.from_h(
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

  # Top-level entry point (see Harness::DSL). Returns a Harness::DSL::Definition.
  def agent(id, &block)
    DSL.agent(id, &block)
  end
end

require_relative "dsl/definition"
