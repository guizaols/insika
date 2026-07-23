# frozen_string_literal: true

require "json"

module Insika
  # Provisioning pack (Phase 6/D4/F6): the PORTABLE form of an agent — a
  # manifest + the prompt files + the skills + the data-tool defs. It's what
  # `docs/prompt-base/06` describes as a workspace, here in a value object
  # consumable by the PackImporter (which emits the authoring Commands). GENERIC
  # per project (NF1): the engine doesn't know consumer-app — the pack is the contract.
  #
  #   config: Hash — manifest (AgentProfile.build attrs: id/model/provider/
  #           limits/metadata/tools_deferred/…). `id`/`model` required there.
  #   files:  { "IDENTITY.md" => "<content>", ... } — prompt files (become
  #           prompt_files via write_agent_file). File name = key.
  #   skills: { "escalation-to-human" => "<SKILL.md>", ... } — 1 per skill.
  #   tools:  [ { ToolDefinition hash }, ... ] — the pack's data-tool defs.
  #
  # Two sources: `from_h` (GatewayClient JSON — provisioning API, task 8) and
  # `from_dir` (a folder on disk per docs/prompt-base/06 — authoring/CLI).
  Pack = Data.define(:config, :files, :skills, :tools) do
    # Raw Hash (string|symbol keys) -> Pack. Tolerates both key conventions
    # (the JSON wire may arrive symbolized or not).
    def self.from_h(hash)
      h = hash || {}
      new(
        config: symbolize(dig(h, :config) || {}),
        files: stringify_keys(dig(h, :files) || {}),
        skills: stringify_keys(dig(h, :skills) || {}),
        tools: Array(dig(h, :tools))
      )
    end

    # Folder on disk (docs/prompt-base/06): `agent.config.json` + `*.md` at the
    # root + `skills/<name>/SKILL.md` + `tools/*.json` (1 ToolDefinition per file).
    def self.from_dir(path)
      root = path.to_s
      config_file = File.join(root, "agent.config.json")
      raise Insika::ValidationError, "pack missing agent.config.json in #{root}" unless File.exist?(config_file)

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

    # `*.md` at the pack ROOT (doesn't descend into skills/). File name = key.
    def self.read_md_files(root)
      Dir.glob(File.join(root, "*.md")).sort.each_with_object({}) do |file, acc|
        acc[File.basename(file)] = File.read(file, encoding: "UTF-8")
      end
    end
    private_class_method :read_md_files

    # `skills/<name>/SKILL.md` -> { "<name>" => "<content>" }.
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
