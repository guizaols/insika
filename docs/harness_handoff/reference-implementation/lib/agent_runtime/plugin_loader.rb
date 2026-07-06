# frozen_string_literal: true

require "yaml"

module AgentRuntime
  # Carregador de plugins no modelo OpenClaw: cada plugin é um diretório com
  # um manifesto (plugin.yml) usado pra DESCOBERTA sem executar código. O
  # runtime então requer o entry Ruby e chama register(api), que registra as
  # tools de verdade. Skills do plugin entram como roots de baixa precedência.
  #
  # Manifesto (plugin.yml):
  #   id: weather
  #   name: Weather
  #   description: ...
  #   entry: plugin.rb          # arquivo Ruby com o módulo de registro
  #   module: WeatherPlugin     # constante que responde a .register(api)
  #   contracts:
  #     tools: [get_weather]    # tools que o plugin declara possuir
  #   tool_metadata:
  #     get_weather: { optional: true }
  #   skills: [skills]          # diretórios de skills (relativos ao root)
  class PluginLoader
    Plugin = Data.define(:id, :name, :root, :tool_names, :skill_dirs)

    # roots ordenados por precedência (maior primeiro). enabled: lista de ids
    # habilitados (bundled precisa ser habilitado explicitamente).
    def initialize(roots, registry:, enabled:)
      @roots = Array(roots)
      @registry = registry
      @enabled = Array(enabled).map(&:to_s)
    end

    # Retorna os diretórios de skills descobertos, pra adicionar ao catálogo.
    def load_all
      seen = {}
      skill_dirs = []

      manifests.each do |file|
        manifest = YAML.safe_load(File.read(file, encoding: "UTF-8")) || {}
        id = manifest["id"].to_s
        next if id.empty?
        next unless @enabled.include?(id)
        next if seen.key?(id) # precedência: primeiro root vence

        root = File.dirname(file)
        plugin = build_plugin(manifest, root)
        register_tools(manifest, plugin)
        skill_dirs.concat(plugin.skill_dirs)
        seen[id] = plugin
      end

      skill_dirs
    end

    private

    def manifests
      @roots.flat_map { |r| Dir.glob(File.join(r, "**", "plugin.yml")).sort }
    end

    def build_plugin(manifest, root)
      tool_names = Array(manifest.dig("contracts", "tools")).map(&:to_s)
      skill_dirs = Array(manifest["skills"]).map { |d| File.join(root, d) }
      Plugin.new(
        id: manifest["id"].to_s,
        name: manifest["name"].to_s,
        root: root,
        tool_names: tool_names,
        skill_dirs: skill_dirs
      )
    end

    # Requer o entry e deixa o plugin registrar suas tools via api. O optional
    # vem do manifesto (tool_metadata), não do código.
    def register_tools(manifest, plugin)
      entry = manifest["entry"]
      return if entry.nil? || plugin.tool_names.empty?

      require File.join(plugin.root, entry)
      mod = Object.const_get(manifest.fetch("module"))
      meta = manifest["tool_metadata"] || {}

      api = RegistrationAPI.new(
        registry: @registry,
        plugin_id: plugin.id,
        declared: plugin.tool_names,
        metadata: meta
      )
      mod.register(api)
    end

    # Fachada passada ao plugin — o análogo Ruby do api.registerTool(...).
    class RegistrationAPI
      def initialize(registry:, plugin_id:, declared:, metadata:)
        @registry = registry
        @plugin_id = plugin_id
        @declared = declared
        @metadata = metadata
      end

      def register_tool(name, klass = nil, &block)
        name = name.to_s
        unless @declared.include?(name)
          warn "[plugin #{@plugin_id}] tool '#{name}' não declarada em contracts.tools — ignorada"
          return
        end
        optional = !!(@metadata.dig(name, "optional"))
        @registry.register(name, klass, optional: optional, plugin: @plugin_id, &block)
      end
    end
  end
end
