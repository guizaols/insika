# frozen_string_literal: true

require "json"

module Harness
  # Pack de provisionamento (Fase 6/D4/F6): a forma PORTÁTIL de um agente — um
  # manifesto + os arquivos de prompt + as skills + as defs de data-tools. É o
  # que o `docs/prompt-base/06` descreve como workspace, aqui num value object
  # consumível pelo PackImporter (que emite os Commands de autoria). GENÉRICO por
  # projeto (NF1): o motor não conhece consumer-app — o pack é o contrato.
  #
  #   config: Hash — manifesto (attrs de AgentProfile.build: id/model/provider/
  #           limits/metadata/tools_deferred/…). `id`/`model` obrigatórios lá.
  #   files:  { "IDENTITY.md" => "<conteúdo>", ... } — arquivos de prompt (viram
  #           prompt_files via write_agent_file). Nome do arquivo = chave.
  #   skills: { "escalation-to-human" => "<SKILL.md>", ... } — 1 por skill.
  #   tools:  [ { ToolDefinition hash }, ... ] — defs de data-tools do pack.
  #
  # Duas origens: `from_h` (JSON do GatewayClient — API de provisionamento, task
  # 8) e `from_dir` (pasta em disco conforme docs/prompt-base/06 — autoria/CLI).
  Pack = Data.define(:config, :files, :skills, :tools) do
    # Hash cru (string|symbol keys) -> Pack. Tolera as duas convenções de chave
    # (o wire JSON pode chegar simbolizado ou não).
    def self.from_h(hash)
      h = hash || {}
      new(
        config: symbolize(dig(h, :config) || {}),
        files: stringify_keys(dig(h, :files) || {}),
        skills: stringify_keys(dig(h, :skills) || {}),
        tools: Array(dig(h, :tools))
      )
    end

    # Pasta em disco (docs/prompt-base/06): `agent.config.json` + `*.md` na raiz +
    # `skills/<nome>/SKILL.md` + `tools/*.json` (1 ToolDefinition por arquivo).
    def self.from_dir(path)
      root = path.to_s
      config_file = File.join(root, "agent.config.json")
      raise Harness::ValidationError, "pack sem agent.config.json em #{root}" unless File.exist?(config_file)

      new(
        config: symbolize(JSON.parse(File.read(config_file, encoding: "UTF-8"))),
        files: read_md_files(root),
        skills: read_skills(File.join(root, "skills")),
        tools: read_tools(File.join(root, "tools"))
      )
    end

    def self.dig(hash, key) = hash[key] || hash[key.to_s]
    private_class_method :dig

    def self.symbolize(hash)
      (hash || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end
    private_class_method :symbolize

    def self.stringify_keys(hash)
      (hash || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
    private_class_method :stringify_keys

    # `*.md` na RAIZ do pack (não desce em skills/). Nome do arquivo = chave.
    def self.read_md_files(root)
      Dir.glob(File.join(root, "*.md")).sort.each_with_object({}) do |file, acc|
        acc[File.basename(file)] = File.read(file, encoding: "UTF-8")
      end
    end
    private_class_method :read_md_files

    # `skills/<nome>/SKILL.md` -> { "<nome>" => "<conteúdo>" }.
    def self.read_skills(dir)
      Dir.glob(File.join(dir, "*", "SKILL.md")).sort.each_with_object({}) do |file, acc|
        acc[File.basename(File.dirname(file))] = File.read(file, encoding: "UTF-8")
      end
    end
    private_class_method :read_skills

    # `tools/*.json` -> [ ToolDefinition hash, ... ].
    def self.read_tools(dir)
      Dir.glob(File.join(dir, "*.json")).sort.map do |file|
        JSON.parse(File.read(file, encoding: "UTF-8"))
      end
    end
    private_class_method :read_tools
  end
end
