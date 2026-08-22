# frozen_string_literal: true

require "yaml"

module Insika
  # Template gallery: example agents shipped INSIDE the gem
  # (`lib/insika/templates/<name>/{agent.rb,README.md}`), one DSL file per
  # template that is BOTH doors — `insika new <name>` copies it for the user
  # to run and edit, and this module `evaluate`s the same file to hand its
  # pack(s) to the Studio's "New from template" gallery. No parallel pack
  # format to drift.
  #
  # A template's `agent.rb` guards its CLI demo footer with
  # `if __FILE__ == $PROGRAM_NAME` (false when this module evaluates it) and
  # ends with the bare `Insika.agent`/`Insika.system` result as its LAST
  # expression, so `evaluate` gets it back as the string-eval's return value
  # — no registration call, no second source of truth.
  module Templates
    ROOT = File.expand_path("templates", __dir__)

    Entry = Data.define(:name, :title, :trail, :description, :capabilities, :studio, :env, :requires) do
      def studio? = studio
    end

    module_function

    # -> [String] template dirs that have an agent.rb, lexicographic.
    def names
      return [] unless Dir.exist?(ROOT)

      Dir.children(ROOT).select { |n| File.file?(agent_path(n)) }.sort
    end

    # -> [Entry] every template, parsed metadata only (no evaluation — cheap,
    # safe to call on every render of the Studio gallery).
    def all = names.map { |n| read(n) }

    # -> Entry for one template. Raises NotFoundError for an unknown name —
    # same discipline as a missing agent/MCP instance.
    def read(name)
      path = agent_path(name)
      raise Insika::NotFoundError, "template '#{name}' not found" unless File.file?(path)

      meta = frontmatter(File.read(path))
      Entry.new(
        name: name.to_s, title: presence(meta["title"]) || name.to_s, trail: presence(meta["trail"]),
        description: meta["description"].to_s,
        capabilities: split_list(meta["capabilities"]),
        studio: meta.fetch("studio", true) != false,
        env: split_list(meta["env"]), requires: presence(meta["requires"])
      )
    end

    # Evaluates the template's agent.rb in an ISOLATED scope (a fresh Object's
    # instance_eval) and returns whatever its last expression is — the built
    # `Insika::DSL::Definition` or `Insika::DSL::System`. $PROGRAM_NAME here is
    # whatever process called this (rspec, the CLI, the Studio server), never
    # this file's path, so the template's own `if __FILE__ == $PROGRAM_NAME`
    # demo footer never runs: no network call, no ARGV parsing, no puts.
    #
    # The fresh-Object receiver keeps a template's local variables and `def`s
    # from leaking into the next one evaluated in the same process; a
    # top-level CONSTANT would still leak (Ruby scopes constant assignment
    # lexically, not by `self`) — wave-1 templates simply don't declare any
    # (the conformance spec, would catch a future one that did).
    def evaluate(name)
      path = agent_path(name)
      raise Insika::NotFoundError, "template '#{name}' not found" unless File.file?(path)

      Object.new.instance_eval(File.read(path), path)
    end

    # -> [Pack] one per agent, regardless of whether the template is a single
    # `Insika.agent` (Definition#to_pack) or a system (System#to_packs).
    def packs_for(name)
      built = evaluate(name)
      built.respond_to?(:to_packs) ? built.to_packs : [built.to_pack]
    end

    def agent_path(name) = File.join(ROOT, name.to_s, "agent.rb")
    def readme_path(name) = File.join(ROOT, name.to_s, "README.md")

    # A `# ---` … `# ---` comment block at the very top of the file, YAML
    # inside (each line stripped of its leading `# `). Not real Ruby
    # frontmatter (there's no such thing) — a convention this module alone
    # parses, so the metadata lives in the one file without needing a
    # side-channel manifest.
    def frontmatter(source)
      lines = source.lines
      # Every template starts with the same magic comment every other .rb
      # file in the gem does — skip it (and any blank line) before looking
      # for the block, so templates don't have to break that convention.
      lines = lines.drop(1) while lines.first && (lines.first.strip.empty? || lines.first.strip == "# frozen_string_literal: true")
      return {} unless lines.first&.strip == "# ---"

      body = lines.drop(1)
                  .take_while { |l| l.strip != "# ---" }
                  .map { |l| l.sub(/\A#\s?/, "") }
                  .join
      YAML.safe_load(body) || {}
    end
    private_class_method :frontmatter

    def split_list(value)
      value.to_s.split(",").map(&:strip).reject(&:empty?)
    end
    private_class_method :split_list

    def presence(str) = Insika::Coercion.presence(str)
    private_class_method :presence
  end
end
