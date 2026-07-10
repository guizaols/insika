# frozen_string_literal: true

require "yaml"
require "time"

module Harness
  module Plugin
    # Carregador de plugins (doc 06 §2-§4; evolui o PluginLoader da Fase 0 sem
    # reescrever — RFC-0003 §7). Roda EXCLUSIVAMENTE no boot, single-fiber, antes
    # do servidor aceitar conexões (doc 06 §5) — zero concorrência.
    #
    # Manifesto: descoberta sem executar código; require do entry só depois de
    # validado. Falha de um plugin não derruba o boot (rollback + warn, doc 06 §6).
    class Loader
      Discovered = Data.define(:id, :name, :root, :tool_names, :workflow_names,
                               :skill_dirs, :prompt_dirs, :config)

      MANIFEST_GLOB = "{harness.plugin.yml,plugin.yml}"
      SUPPORTED_CONTRACTS = %w[tools workflows].freeze

      # registries: { tools:, workflows:, policies: } (Registry), hooks: (Hooks),
      # middleware:/context_providers: (coleções que respondem a <<).
      def initialize(roots:, registries:, enabled:, event_stream:)
        @roots = Array(roots)
        @registries = registries
        @enabled = Array(enabled).map(&:to_s)
        @event_stream = event_stream
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

          warn_reserved(manifest, id)
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

      # Localizado de propósito p/ a task 22 estender (roots anunciados por gem).
      def enabled?(id, _root)
        @enabled.include?(id)
      end

      private

      # Um manifesto por diretório: harness.plugin.yml precede plugin.yml (mesmo
      # dir). Ordem preservada (precedência de root — primeiro vence via `seen`).
      def manifest_files
        selected = {}
        @roots.each do |root|
          Dir.glob(File.join(root, "**", MANIFEST_GLOB)).sort.each do |file|
            dir = File.dirname(file)
            selected[dir] = file if selected[dir].nil? || File.basename(file) == "harness.plugin.yml"
          end
        end
        selected.values
      end

      def load_manifest(file)
        manifest = YAML.safe_load(File.read(file, encoding: "UTF-8")) || {}
        return nil unless manifest.is_a?(Hash)

        if File.basename(file) == "plugin.yml"
          warn "[plugin #{manifest['id']}] plugin.yml está deprecado — renomeie para harness.plugin.yml"
        end
        manifest
      rescue StandardError => e
        warn "[plugin] manifesto ilegível #{file}: #{e.class}: #{e.message}"
        nil
      end

      def warn_reserved(manifest, id)
        return unless manifest.dig("contracts", "capabilities")

        warn "[plugin #{id}] contracts.capabilities é reservado (Fase 2) — ignorado"
      end

      # -> config Hash (válida) | :skip (fail-closed por plugin, doc 06 §3).
      def validate_config(manifest, id)
        schema = manifest["config_schema"]
        config = manifest["config"] || {}
        return config if schema.nil?

        errors = ConfigSchema.validate(schema, config)
        return config if errors.empty?

        warn "[plugin #{id}] config inválida:\n#{errors.map { |e| "  - #{e}" }.join("\n")}"
        :skip
      end

      def build_discovered(manifest, root, config)
        Discovered.new(
          id: manifest["id"].to_s, name: manifest["name"].to_s, root: root,
          tool_names: Array(manifest.dig("contracts", "tools")).map(&:to_s),
          workflow_names: Array(manifest.dig("contracts", "workflows")).map(&:to_s),
          skill_dirs: Array(manifest["skills"]).map { |d| File.join(root, d) },
          prompt_dirs: Array(manifest["prompts"]).map { |d| File.join(root, d) },
          config: config
        )
      end

      # require + const_get + register(api) + commit do staging. Falha ->
      # warn+backtrace, rollback das entradas parciais (L3), plugin descartado,
      # boot continua. Sem entry: só skills/prompts (nenhum registro).
      def load_entry(manifest, discovered)
        entry = manifest["entry"]
        return true if entry.nil?

        api = RegistrationAPI.new(
          registries: @registries, plugin_id: discovered.id,
          tool_names: discovered.tool_names, workflow_names: discovered.workflow_names,
          tool_metadata: manifest["tool_metadata"] || {}, config: discovered.config
        )
        require File.join(discovered.root, entry)
        Object.const_get(manifest.fetch("module")).register(api)
        api.commit!
        true
      rescue StandardError => e
        warn "[plugin #{discovered.id}] falha ao carregar: #{e.class}: #{e.message}\n" \
             "#{Array(e.backtrace).first(5).join("\n")}"
        rollback(discovered.id)
        false
      end

      def rollback(id)
        %i[tools workflows policies].each { |kind| @registries[kind]&.deregister_plugin(id) }
      end

      def emit_loaded(discovered)
        @event_stream.emit(Harness::Event.new(
                             type: :plugin_loaded,
                             data: { id: discovered.id, tools: discovered.tool_names,
                                     skills: discovered.skill_dirs },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end

      # Fachada passada ao plugin (doc 06 §2). Contrato exigido só p/ tools e
      # workflows (endereçáveis por nome, L5); middleware/hooks/providers são
      # STAGED e efetivados por commit! só quando register(api) volta sem exceção
      # (materializa a garantia de rollback — nada parcial sobra).
      class RegistrationAPI
        def initialize(registries:, plugin_id:, tool_names:, workflow_names:, tool_metadata:, config:)
          @registries = registries
          @plugin_id = plugin_id
          @tool_names = tool_names
          @workflow_names = workflow_names
          @tool_metadata = tool_metadata
          @config = config.freeze
          @staged_middleware = []
          @staged_providers = []
          @staged_hooks = []
        end

        def register_tool(name, klass = nil, &block)
          name = name.to_s
          unless @tool_names.include?(name)
            warn "[plugin #{@plugin_id}] tool '#{name}' não declarada em contracts.tools — ignorada"
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
            warn "[plugin #{@plugin_id}] workflow '#{name}' não declarado em contracts.workflows — ignorado"
            return
          end
          @registries[:workflows].register(name, callable, plugin: @plugin_id, &block)
        end

        def register_policy(name, klass)
          @registries[:policies].register(name, klass, plugin: @plugin_id)
        end

        def register_middleware(instance) = @staged_middleware << instance
        def register_context_provider(instance) = @staged_providers << instance
        def register_hook(pair, before: nil, after: nil) = (@staged_hooks << [pair, before, after])
        def config = @config

        def commit!
          @staged_middleware.each { |m| @registries[:middleware] << m }
          @staged_providers.each { |p| @registries[:context_providers] << p }
          @staged_hooks.each { |pair, before, after| @registries[:hooks].register(pair, before: before, after: after) }
        end
      end

      # Validador subset de JSON Schema (L4 — sem gem; trocável na Fase 2).
      # validate(schema, value) -> [String] (vazio = válido). Schema inválido E
      # config que não valida caem na mesma lista (fail-closed por plugin).
      module ConfigSchema
        KEYWORDS = %w[type properties required additionalProperties enum].freeze
        TYPES = {
          "object" => [Hash], "array" => [Array], "string" => [String],
          "integer" => [Integer], "number" => [Numeric],
          "boolean" => [TrueClass, FalseClass], "null" => [NilClass]
        }.freeze

        def self.validate(schema, value, path = "config")
          return ["#{path}: schema deve ser um Hash"] unless schema.is_a?(Hash)

          errors = []
          unknown = schema.keys - KEYWORDS
          errors << "#{path}: keyword(s) não suportada(s): #{unknown.join(', ')}" unless unknown.empty?
          errors.concat(check_type(schema, value, path))
          errors.concat(check_enum(schema, value, path))
          errors.concat(check_object(schema, value, path))
          errors
        end

        def self.check_type(schema, value, path)
          return [] unless schema.key?("type")

          klasses = TYPES[schema["type"]]
          return ["#{path}: type desconhecido: #{schema['type'].inspect}"] if klasses.nil?
          return [] if klasses.any? { |k| value.is_a?(k) }

          ["#{path}: esperado #{schema['type']}, veio #{value.class}"]
        end

        def self.check_enum(schema, value, path)
          return [] unless schema.key?("enum")
          return [] if Array(schema["enum"]).include?(value)

          ["#{path}: valor #{value.inspect} fora do enum"]
        end

        def self.check_object(schema, value, path)
          return [] unless schema.key?("properties") || schema.key?("required") ||
                           schema.key?("additionalProperties")

          props = schema["properties"] || {}
          return ["#{path}: properties deve ser Hash"] unless props.is_a?(Hash)
          return [] unless value.is_a?(Hash) # keywords de objeto só valem p/ Hash

          errors = []
          props.each { |k, sub| errors.concat(validate(sub, value[k], "#{path}.#{k}")) if value.key?(k) }
          Array(schema["required"]).each do |req|
            errors << "#{path}: chave obrigatória ausente: #{req}" unless value.key?(req)
          end
          if schema["additionalProperties"] == false && !(extra = value.keys - props.keys).empty?
            errors << "#{path}: chaves não permitidas: #{extra.join(', ')}"
          end
          errors
        end
      end
    end
  end
end
