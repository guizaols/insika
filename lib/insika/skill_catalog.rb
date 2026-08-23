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
    # Eagerness is NOT here. It used to be a frontmatter flag, i.e. a property of the
    # SKILL — but skills are shared between agents, so one flag forced one decision
    # onto every allowlist holding the skill. It is a property of the AGENT
    # (`profile.skills_eager`, see #eager_for).
    #
    # companions: names of the skills this one cannot work without. Injecting or
    # loading a skill brings them along, so the half-recipe state cannot be assembled —
    # a reference table arriving without the procedure that reads it is worse than
    # nothing, because the model then never asks for the other half.
    Skill = Data.define(:name, :description, :path, :body, :triggers, :companions)

    # roots ordered by PRECEDENCE (highest first): workspace, managed,
    # bundled. Same name in more than one root: the first wins.
    #
    # store (optional): a SkillStore with the skills AUTHORED in the Studio.
    # They overlay the on-disk ones (seed) — the Store wins, it is the source of truth.
    # Nil = disk-only behavior, zero regression.
    def initialize(roots, store: nil)
      @roots = Array(roots)
      @store = store
      @skills, @agent_skills = load_all
    end

    # The SkillStore the catalog overlays — the composition root hands it to
    # the harvest (the dedup reads the AUTHORED skills the catalog serves).
    attr_reader :store

    # `agent` (an agent id) resolves the AGENT SCOPE first, then the shared one — the
    # same precedence chain the catalog already runs for store-over-disk and
    # workspace-over-managed-over-bundled, with one more dimension.
    #
    # Three cases fall out of that one rule: SHARED (only the shared record exists),
    # OVERRIDE (both exist, the agent's wins) and AGENT-PRIVATE (only the agent record
    # exists — invisible elsewhere, and its name may collide freely).
    #
    # Without `agent` the shared scope is all there is, which is what every caller
    # that has no agent in hand (the Studio's shared editor, a bare catalog) means.
    def all(agent: nil)
      shared = @skills
      overrides = agent_scope(agent)
      return shared.values if overrides.empty?

      shared.merge(overrides).values
    end

    def find(name, agent: nil)
      agent_scope(agent)[name.to_s] || @skills[name.to_s]
    end

    # Reloads from disk + Store and SWAPS the index atomically: an
    # authored/edited skill takes effect without a restart. A turn in progress
    # captured @skills at dispatch, so it does not see the swap mid-flight.
    def reload
      @skills, @agent_skills = load_all
      self
    end

    # Appends roots at the END — lowest precedence, so a workspace skill always
    # overrides a same-named one shipped by a plugin. This is how
    # the plugin Loader's `skill_dirs` reach the catalog at boot; reloads only
    # when something new actually arrived.
    def add_roots(dirs)
      added = Array(dirs).map { |d| File.expand_path(d.to_s) } - @roots.map { |r| File.expand_path(r) }
      return self if added.empty?

      @roots.concat(added)
      reload
    end

    # Per-agent allowlist: nil -> all | [] -> none | [names] -> subset. `agent`
    # selects WHICH body each allowed name resolves to (see #find); the allowlist is
    # by NAME either way, so specializing a skill never touches the allowlist.
    def effective(skills_policy, agent: nil)
      Allowlist.filter(all(agent: agent), skills_policy) { |s| s.name }
    end

    # THE single definition of "always in the prompt", consulted by all three
    # surfaces that must agree: the body provider (injects these), the level-1
    # catalog (hides them) and load_skill (refuses them). Split the rule across three
    # files and they drift — which is the failure this whole feature came from.
    #
    # `profile.skills_eager` — a PER-AGENT decision, so a shared skill stays shared:
    #   nil | false  -> none (progressive disclosure; the default)
    #   true         -> every allowed skill (blanket; only for a corpus that fits the budget)
    #   [names]      -> exactly these
    #
    # Deliberately NOT `Allowlist.filter`: there nil means ALL, which is the safe
    # default for `skills`/`tools_allow` where nil is "no policy". Here nil must mean
    # NONE — an unconfigured agent waking up with every skill body on every turn is
    # the opposite of a safe default. A name that is not in the agent's `skills`
    # allowlist is a silent no-op here (the intersection with `effective`); `doctor`
    # flags it, because the operator who wrote the name meant it.
    def eager_for(profile)
      allowed = effective(profile.skills, agent: profile.id)
      spec = profile.skills_eager
      return allowed if blanket?(spec)
      return [] if spec.nil? || spec == false

      names = Array(spec).map { |n| n.to_s.strip }
      allowed.select { |s| names.include?(s.name) }
    end

    # The complement: what the model still has to ASK for — and therefore what the
    # level-1 list advertises and load_skill will serve.
    def lazy_for(profile) = effective(profile.skills, agent: profile.id) - eager_for(profile)

    # Level 1: compact list injected into the system prompt. Metadata only.
    # Receives the set already filtered by the agent.
    #
    # `when=` carries the skill's `triggers:` — THE ROUTING TABLE, GENERATED. What
    # actually made activation reliable on the pilot was a hand-written companion file
    # listing each skill with its trigger phrases, and nothing checked it against the
    # catalog: a skill created at 11:28 was invisible to a table written the day
    # before, and the model obeyed the table. Rendering the same information from the
    # catalog means it cannot disagree with the allowlist — a newly allowed skill
    # appears the moment it is allowed. Detecting that drift would have been strictly
    # worse than removing its source.
    def format_for_prompt(skills = all)
      return "" if skills.empty?

      entries = skills.map do |s|
        when_attr = Array(s.triggers).empty? ? "" : %( when="#{Array(s.triggers).join('; ')}")
        %(  <skill name="#{s.name}"#{when_attr}>#{s.description}</skill>)
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

    # The blanket switch, tolerant of the strings a form / JSON round-trip produces
    # ("1" from a checkbox, "true" from a pack) — same reading as
    # AgentProfile#stream_public?. Anything else (a list, nil, false) is not blanket.
    def blanket?(spec) = Coercion.truthy?(spec)

    # An agent's override index; {} for a nil agent or one that specialized nothing.
    def agent_scope(agent) = agent.nil? ? {} : (@agent_skills[agent.to_s] || {})

    # -> [shared index, { agent_id => index }].
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
      [found, load_agent_scopes]
    end

    # Store skills overlay the on-disk ones (authored > seed). Sentinel path
    # "store:<name>" — not a real file (load_skill uses `body`, not the path).
    def overlay_store(found)
      return unless @store

      @store.all.each do |name, content|
        skill = parse_content(content.to_s, path: "store:#{name}", key: name)
        found[name.to_s] = skill if skill # Store wins
      end
    end

    # Per-agent overrides / private skills, one index per agent. A store that predates
    # the agent dimension answers nothing here, so this is {} and every lookup falls
    # straight through to the shared scope.
    def load_agent_scopes
      return {} unless @store.respond_to?(:agents)

      @store.agents.each_with_object({}) do |agent, acc|
        index = {}
        @store.all(agent: agent).each do |name, content|
          skill = parse_content(content.to_s, path: "store:#{agent}/#{name}", key: name)
          index[name.to_s] = skill if skill
        end
        acc[agent.to_s] = index unless index.empty?
      end
    end

    # `key` = THE STORE POSITION, and it wins over the frontmatter `name:`. An override
    # authored for one agent still says `name: escalation-to-human` inside — that is
    # deliberate, it is the same skill specialized — and indexing by the parsed name
    # would clobber the shared record globally, which is the exact bug the agent scope
    # exists to fix. It also makes a pack whose directory name and frontmatter name
    # disagree resolvable: the allowlist is written from the directory.
    def parse_content(raw, path:, key: nil)
      match = raw.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
      return nil unless match

      # Tolerant frontmatter: real packs have `: ` in the description prose, which
      # strict YAML rejected (the pack would not load).
      meta = Insika::Frontmatter.parse(match[1])
      name = key || meta["name"]
      return nil unless name && Coercion.present?(meta["name"])

      Skill.new(
        name: name.to_s,
        description: meta["description"].to_s,
        path: path,
        body: match[2].strip,
        triggers: parse_list(meta["triggers"]),
        companions: parse_list(meta["companions"])
      )
    end

    # `triggers:` / `companions:` frontmatter. YAML list, or comma-separated string
    # under the lenient parse (which yields the whole value as one String).
    def parse_list(raw)
      list = raw.is_a?(String) ? raw.split(",") : Array(raw)
      list.map { |t| t.to_s.strip }.reject(&:empty?)
    end
  end
end
