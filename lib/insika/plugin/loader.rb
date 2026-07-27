# frozen_string_literal: true

require "yaml"
require "time"

module Insika
  module Plugin
    # Plugin loader. Runs EXCLUSIVELY at boot, single-fiber, before
    # the server accepts connections — zero concurrency.
    #
    # Manifest: discovery without executing code; the entry require only happens
    # after validation. A plugin failure doesn't bring down boot (rollback + warn).
    class Loader
      Discovered = Data.define(:id, :name, :root, :tool_names, :workflow_names,
                               :capability_names, :skill_dirs, :prompt_dirs, :config)

      MANIFEST_GLOB = "{insika.plugin.yml,plugin.yml}"
      SUPPORTED_CONTRACTS = %w[tools workflows capabilities].freeze

      # registries: { tools:, workflows:, policies: } (Registry), hooks: (Hooks),
      # middleware:/context_providers: (collections that respond to <<).
      # announced_roots:/disabled: materialize per-root-class enablement;
      # empty defaults keep the signature valid.
      def initialize(roots:, registries:, enabled:, event_stream:,
                     announced_roots: [], disabled: [])
        @roots = Array(roots)
        @registries = registries
        @enabled = Array(enabled).map(&:to_s)
        @event_stream = event_stream
        @announced_roots = Array(announced_roots).map { |r| File.expand_path(r.to_s) }
        @disabled = Array(disabled).map(&:to_s)
      end

      # -> { skill_dirs: [], prompt_dirs: [], plugins: [Discovered] }
      def load_all
        seen = {}
        skill_dirs = []
        prompt_dirs = []
        plugins = []

        manifest_files.each do |file|
          manifest = load_manifest(file)
          next if manifest.nil?

          id = manifest["id"].to_s
          next if id.empty? || !enabled?(id, File.dirname(file)) || seen.key?(id)

          config = validate_config(manifest, id)
          next if config == :skip

          discovered = build_discovered(manifest, File.dirname(file), config)
          next unless load_entry(manifest, discovered)

          skill_dirs.concat(discovered.skill_dirs)
          prompt_dirs.concat(discovered.prompt_dirs)
          plugins << discovered
          seen[id] = discovered
          emit_loaded(discovered)
        end

        { skill_dirs: skill_dirs, prompt_dirs: prompt_dirs, plugins: plugins }
      end

      # Per-root-class enablement: an announced gem is
      # default-enabled, disableable via disabled:; workspace and bundled require
      # explicit enabled:. disabled: is an absolute veto (deny wins,
      # like the allowlists) — an id in disabled won't load even if it's in enabled.
      def enabled?(id, plugin_dir)
        return false if @disabled.include?(id)

        announced?(plugin_dir) ? true : @enabled.include?(id)
      end

      private

      def announced?(plugin_dir)
        dir = File.expand_path(plugin_dir)
        @announced_roots.any? { |root| dir == root || dir.start_with?("#{root}#{File::SEPARATOR}") }
      end

      # One manifest per directory: insika.plugin.yml takes precedence over
      # plugin.yml (same dir). Order preserved (root precedence — first wins via `seen`).
      def manifest_files
        selected = {}
        @roots.each do |root|
          Dir.glob(File.join(root, "**", MANIFEST_GLOB)).sort.each do |file|
            dir = File.dirname(file)
            selected[dir] = file if selected[dir].nil? || File.basename(file) == "insika.plugin.yml"
          end
        end
        selected.values
      end

      def load_manifest(file)
        manifest = YAML.safe_load(File.read(file, encoding: "UTF-8")) || {}
        return nil unless manifest.is_a?(Hash)

        if File.basename(file) == "plugin.yml"
          warn "[plugin #{manifest['id']}] plugin.yml is deprecated — rename to insika.plugin.yml"
        end
        manifest
      rescue StandardError => e
        warn "[plugin] unreadable manifest #{file}: #{e.class}: #{e.message}"
        nil
      end

      # -> config Hash (valid) | :skip (fail-closed per plugin).
      def validate_config(manifest, id)
        schema = manifest["config_schema"]
        config = manifest["config"] || {}
        return config if schema.nil?

        errors = ConfigSchema.validate(schema, config)
        return config if errors.empty?

        warn "[plugin #{id}] invalid config:\n#{errors.map { |e| "  - #{e}" }.join("\n")}"
        :skip
      end

      def build_discovered(manifest, root, config)
        Discovered.new(
          id: manifest["id"].to_s, name: manifest["name"].to_s, root: root,
          tool_names: Array(manifest.dig("contracts", "tools")).map(&:to_s),
          workflow_names: Array(manifest.dig("contracts", "workflows")).map(&:to_s),
          capability_names: Array(manifest.dig("contracts", "capabilities")).map(&:to_s),
          skill_dirs: Array(manifest["skills"]).map { |d| File.join(root, d) },
          prompt_dirs: Array(manifest["prompts"]).map { |d| File.join(root, d) },
          config: config
        )
      end

      # require + const_get + register(api) + commit of the staging. On failure ->
      # warn+backtrace, rollback of the partial entries, plugin discarded,
      # boot continues. Without an entry: only skills/prompts (no registration).
      def load_entry(manifest, discovered)
        entry = manifest["entry"]
        return true if entry.nil?

        api = RegistrationAPI.new(
          registries: @registries, plugin_id: discovered.id,
          tool_names: discovered.tool_names, workflow_names: discovered.workflow_names,
          capability_names: discovered.capability_names,
          tool_metadata: manifest["tool_metadata"] || {}, config: discovered.config
        )
        require File.join(discovered.root, entry)
        Object.const_get(manifest.fetch("module")).register(api)
        api.commit!
        true
      rescue StandardError => e
        warn "[plugin #{discovered.id}] failed to load: #{e.class}: #{e.message}\n" \
             "#{Array(e.backtrace).first(5).join("\n")}"
        rollback(discovered.id)
        false
      end

      def rollback(id)
        %i[tools workflows policies capabilities].each { |kind| @registries[kind]&.deregister_plugin(id) }
      end

      def emit_loaded(discovered)
        @event_stream.emit(Insika::Event.new(
                             type: :plugin_loaded,
                             data: { id: discovered.id, tools: discovered.tool_names,
                                     skills: discovered.skill_dirs },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end

      # Facade passed to the plugin. A contract is required only for tools and
      # workflows (addressable by name); middleware/hooks/providers are
      # STAGED and made effective by commit! only when register(api) returns
      # without an exception (materializes the rollback guarantee — nothing partial remains).
      class RegistrationAPI
        def initialize(registries:, plugin_id:, tool_names:, workflow_names:,
                       tool_metadata:, config:, capability_names: [])
          @registries = registries
          @plugin_id = plugin_id
          @tool_names = tool_names
          @workflow_names = workflow_names
          @capability_names = capability_names
          @tool_metadata = tool_metadata
          @config = config.freeze
          @staged_middleware = []
          @staged_providers = []
          @staged_hooks = []
          @staged_capabilities = []
        end

        def register_tool(name, klass = nil, &block)
          name = name.to_s
          unless @tool_names.include?(name)
            warn "[plugin #{@plugin_id}] tool '#{name}' not declared in contracts.tools — ignored"
            return
          end
          meta = @tool_metadata[name] || {}
          @registries[:tools].register(name, klass, plugin: @plugin_id,
                                                    optional: !!meta["optional"],
                                                    side_effect: !!meta["side_effect"], &block)
        end

        def register_workflow(name, callable = nil, &block)
          name = name.to_s
          unless @workflow_names.include?(name)
            warn "[plugin #{@plugin_id}] workflow '#{name}' not declared in contracts.workflows — ignored"
            return
          end
          @registries[:workflows].register(name, callable, plugin: @plugin_id, &block)
        end

        def register_policy(name, klass)
          @registries[:policies].register(name, klass, plugin: @plugin_id)
        end

        # Mirrors register_tool ("not declared -> warn + ignore"), + tool:/workflow:
        # exclusivity and the warn for kind :workflow (no consumer in this slice).
        # Staged; made effective at commit! (nothing partial if register(api) raises).
        def register_capability(name, tool: nil, workflow: nil, priority: nil, available: nil)
          name = name.to_s
          unless @capability_names.include?(name)
            warn "[plugin #{@plugin_id}] capability '#{name}' not declared in contracts.capabilities — ignored"
            return
          end

          if tool && workflow
            warn "[plugin #{@plugin_id}] capability '#{name}': provide only tool: OR workflow:, not both — ignored"
            return
          end

          impl_name, kind =
            if tool then [tool.to_s, :tool]
            elsif workflow then [workflow.to_s, :workflow]
            end

          if impl_name.nil?
            warn "[plugin #{@plugin_id}] capability '#{name}': informe tool: ou workflow: — ignorada"
            return
          end

          if kind == :workflow
            warn "[plugin #{@plugin_id}] capability '#{name}' (kind: workflow) registered without a consumer " \
                 "in this slice — agent exposure is follow-up (P2B-01 L5)"
          end

          @staged_capabilities << { capability: name, impl_name: impl_name, kind: kind,
                                    priority: priority, available: available }
        end

        def register_middleware(instance) = @staged_middleware << instance
        def register_context_provider(instance) = @staged_providers << instance

        # Validates the pair AT stage time (not only at commit): this way an invalid
        # pair raises INSIDE register(api) -> the staging is discarded and the rollback
        # covers everything. If validation happened only at commit!, middleware/providers
        # would already have been made effective when the bad hook raised.
        def register_hook(pair, before: nil, after: nil)
          unless Insika::Hooks::PAIRS.include?(pair)
            raise ArgumentError, "unknown hook pair: #{pair.inspect}"
          end

          @staged_hooks << [pair, before, after]
        end

        def config = @config

        # Atomic by construction: the hook pairs were already validated at stage
        # time, so no line here raises (array <<, hooks.register of a valid pair).
        def commit!
          @staged_middleware.each { |m| @registries[:middleware] << m }
          @staged_providers.each { |p| @registries[:context_providers] << p }
          @staged_hooks.each { |pair, before, after| @registries[:hooks].register(pair, before: before, after: after) }
          @staged_capabilities.each do |c|
            @registries[:capabilities].register(c[:capability], impl_name: c[:impl_name], kind: c[:kind],
                                                                 plugin: @plugin_id, priority: c[:priority],
                                                                 available: c[:available])
          end
        end
      end

      # Subset JSON Schema validator (no gem; swappable).
      # validate(schema, value) -> [String] (empty = valid). An invalid schema AND
      # a config that fails validation land in the same list (fail-closed per plugin).
      module ConfigSchema
        KEYWORDS = %w[type properties required additionalProperties enum].freeze
        TYPES = {
          "object" => [Hash], "array" => [Array], "string" => [String],
          "integer" => [Integer], "number" => [Numeric],
          "boolean" => [TrueClass, FalseClass], "null" => [NilClass]
        }.freeze

        def self.validate(schema, value, path = "config")
          return ["#{path}: schema must be a Hash"] unless schema.is_a?(Hash)

          errors = []
          unknown = schema.keys - KEYWORDS
          errors << "#{path}: unsupported keyword(s): #{unknown.join(', ')}" unless unknown.empty?
          errors.concat(check_type(schema, value, path))
          errors.concat(check_enum(schema, value, path))
          errors.concat(check_object(schema, value, path))
          errors
        end

        def self.check_type(schema, value, path)
          return [] unless schema.key?("type")

          klasses = TYPES[schema["type"]]
          return ["#{path}: unknown type: #{schema['type'].inspect}"] if klasses.nil?
          return [] if klasses.any? { |k| value.is_a?(k) }

          ["#{path}: expected #{schema['type']}, got #{value.class}"]
        end

        def self.check_enum(schema, value, path)
          return [] unless schema.key?("enum")
          return [] if Array(schema["enum"]).include?(value)

          ["#{path}: value #{value.inspect} not in enum"]
        end

        def self.check_object(schema, value, path)
          return [] unless schema.key?("properties") || schema.key?("required") ||
                           schema.key?("additionalProperties")

          props = schema["properties"] || {}
          return ["#{path}: properties must be a Hash"] unless props.is_a?(Hash)
          return [] unless value.is_a?(Hash) # object keywords only apply to a Hash

          errors = []
          props.each { |k, sub| errors.concat(validate(sub, value[k], "#{path}.#{k}")) if value.key?(k) }
          Array(schema["required"]).each do |req|
            errors << "#{path}: missing required key: #{req}" unless value.key?(req)
          end
          if schema["additionalProperties"] == false && !(extra = value.keys - props.keys).empty?
            errors << "#{path}: keys not allowed: #{extra.join(', ')}"
          end
          errors
        end
      end
    end
  end
end
