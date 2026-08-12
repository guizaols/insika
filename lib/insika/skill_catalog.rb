# frozen_string_literal: true

require "yaml"

module Insika
  # OpenClaw / AgentSkills convention: each skill is a directory with a
  # SKILL.md (YAML frontmatter + markdown body). Progressive disclosure:
  # level 1 = name+description in the system prompt; level 2 = body loaded
  # on demand by the load_skill tool.
  #
  # Consumed by the Executor (skill_catalog:) and by stage 3
  # (effective/format_for_prompt).
  class SkillCatalog
    Skill = Data.define(:name, :description, :path, :body, :triggers)

    # roots ordered by PRECEDENCE (highest first): workspace, managed,
    # bundled. Same name in more than one root: the first wins.
    #
    # store (optional): a SkillStore with the skills AUTHORED in the Studio.
    # They overlay the on-disk ones (seed) — the Store wins, it is the source of truth.
    # Nil = disk-only behavior, zero regression.
    def initialize(roots, store: nil)
      @roots = Array(roots)
      @store = store
      @skills = load_all
    end

    def all
      @skills.values
    end

    def find(name)
      @skills[name.to_s]
    end

    # Reloads from disk + Store and SWAPS the index atomically: an
    # authored/edited skill takes effect without a restart. A turn in progress
    # captured @skills at dispatch, so it does not see the swap mid-flight.
    def reload
      @skills = load_all
      self
    end

    # Per-agent allowlist: nil -> all | [] -> none | [names] -> subset.
    def effective(skills_policy)
      Allowlist.filter(all, skills_policy) { |s| s.name }
    end

    # Level 1: compact list injected into the system prompt. Metadata only.
    # Receives the set already filtered by the agent.
    def format_for_prompt(skills = all)
      return "" if skills.empty?

      entries = skills.map do |s|
        %(  <skill name="#{s.name}">#{s.description}</skill>)
      end.join("\n")

      <<~PROMPT.strip
        <available_skills>
        #{entries}
        </available_skills>

        Before ANY reply or tool call: scan the skills above. If one matches
        or is even partially relevant to the task, you MUST call
        `load_skill("name")` FIRST and follow what it returns. Err on the
        side of loading. Only skip when genuinely none apply.
      PROMPT
    end

    private

    def load_all
      found = {}
      @roots.each do |root|
        Dir.glob(File.join(root, "**", "SKILL.md")).sort.each do |file|
          skill = parse_content(File.read(file, encoding: "UTF-8"), path: file)
          next unless skill

          found[skill.name] ||= skill # precedence: first root wins
        end
      end
      overlay_store(found)
      found
    end

    # Store skills overlay the on-disk ones (authored > seed). Sentinel path
    # "store:<name>" — not a real file (load_skill uses `body`, not the path).
    def overlay_store(found)
      return unless @store

      @store.all.each do |name, content|
        skill = parse_content(content.to_s, path: "store:#{name}")
        found[skill.name] = skill if skill # Store wins
      end
    end

    def parse_content(raw, path:)
      match = raw.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
      return nil unless match

      # Tolerant frontmatter: real packs have `: ` in the description prose, which
      # strict YAML rejected (the pack would not load).
      meta = Insika::Frontmatter.parse(match[1])
      name = meta["name"]
      return nil unless name

      Skill.new(
        name: name.to_s,
        description: meta["description"].to_s,
        path: path,
        body: match[2].strip,
        triggers: parse_triggers(meta["triggers"])
      )
    end

    # `triggers:` frontmatter — deterministic activation (SkillTrigger
    # provider): when the user message matches one, the body is injected
    # this turn without a load_skill call. YAML list, or comma-separated
    # string under the lenient parse.
    def parse_triggers(raw)
      list = raw.is_a?(String) ? raw.split(",") : Array(raw)
      list.map { |t| t.to_s.strip }.reject(&:empty?)
    end
  end
end
