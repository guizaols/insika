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
    # eager: `eager: true` in the frontmatter — this skill's body is in the prompt on
    # EVERY turn, so it is not a decision and cannot be missed. It also leaves the
    # level-1 catalog and the load_skill allowlist: a skill already present in full
    # has no level 2 to fetch. Reserve it for what every turn needs (output format,
    # markers); leave the discretionary ones model-loaded, because THERE the
    # load_skill call is the only record of which skill the model actually reached for.
    Skill = Data.define(:name, :description, :path, :body, :triggers, :eager)

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

    # THE single definition of "always in the prompt", consulted by all three
    # surfaces that must agree: the body provider (injects these), the level-1
    # catalog (hides them) and load_skill (refuses them). Split the rule across three
    # files and they drift — which is the failure this whole feature came from.
    #
    # `profile.skills_eager` is the blanket switch (every allowed skill, for a corpus
    # that fits the budget); the frontmatter `eager:` is the per-skill one.
    def eager_for(profile)
      allowed = effective(profile.skills)
      profile.skills_eager ? allowed : allowed.select(&:eager)
    end

    # The complement: what the model still has to ASK for — and therefore what the
    # level-1 list advertises and load_skill will serve.
    def lazy_for(profile) = effective(profile.skills) - eager_for(profile)

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
        triggers: parse_triggers(meta["triggers"]),
        eager: truthy?(meta["eager"])
      )
    end

    # The lenient frontmatter parser yields strings, so "true"/"yes"/"1" all have to
    # read as true — an operator who writes `eager: yes` means yes.
    def truthy?(raw) = %w[true yes 1 on].include?(raw.to_s.strip.downcase)

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
