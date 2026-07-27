# frozen_string_literal: true

module Insika
  # LLM-first onboarding surface (item 20 / §5.6). The "Flue trick": the insika
  # serves, from itself, a `start.md` addressed to the DEVELOPER'S OWN coding agent
  # ("Read <base>/start.md then help me build my first agent") plus a machine-readable
  # `/models.json` and the public docs mirrored as raw markdown. It is `rails new`
  # reimplemented as a prompt, with the generator being the coding agent the developer
  # already has.
  #
  # Pure and data-defined: everything it serves comes from injected sources — a
  # `start.md` TEMPLATE file, a NAME=>path map of public docs, and (optionally) the
  # SettingsStore / LLMProviderStore / the served agents. It only READS (no writes, no
  # RubyLLM, no Executor), so the transport can call it under the constitutional rule.
  # Secrets never leak: `models_json` reads the MASKED provider view and omits base
  # urls/keys entirely — only slugs and model ids, which is all a coding agent needs to
  # write a correct `model`/`provider` line.
  #
  # Injection (all optional but `template_path`/`docs`):
  #   template_path  -> the start.md source (a real file, so it stays reviewable/raw)
  #   docs           -> { "slug" => "/abs/path.md", … } served at GET /docs/:slug.md.
  #                     An explicit ALLOWLIST — the gitignored internal docs are never
  #                     in it, and there is no filesystem traversal (only map keys).
  #   settings_store -> platform default_model / fallbacks / thinking (nil = omit)
  #   provider_store -> configured providers + their model ids, MASKED (nil = omit)
  #   agents         -> callable returning [{ id:, model:, provider:, description: }]
  #                     for the agents already served here (nil = none)
  class Onboarding
    # Bumped when the models.json SHAPE changes (its own contract, independent of the
    # settings schema). A consuming coding agent can branch on it.
    MODELS_SCHEMA_VERSION = 1

    # The PUBLIC docs allowlist, repo-relative: slug => path. Explicit on purpose —
    # the gitignored internal docs (FOLLOWUP / techspec / TRANSLATION-TRACKER / …)
    # are NEVER here, so /docs can only ever serve OSS material. Kept in sync with the
    # tracked `.md` prose (README + docs/*.md).
    PUBLIC_DOCS = {
      "readme" => "README.md",
      "why" => "docs/WHY.md",
      "agents" => "docs/AGENTS.md",
      "tools" => "docs/TOOLS.md",
      "skills" => "docs/SKILLS.md",
      "context" => "docs/CONTEXT.md",
      "security" => "docs/SECURITY.md",
      "architecture" => "docs/ARCHITECTURE.md",
      "running-local" => "docs/RUNNING-LOCAL.md",
      "deploy" => "docs/DEPLOY.md",
      "sandbox" => "docs/SANDBOX.md",
      "benchmark" => "docs/BENCHMARK.md",
      "observability" => "docs/OBSERVABILITY.md",
      "loadtest" => "docs/LOADTEST.md"
    }.freeze

    # Repo-relative path to the start.md template.
    TEMPLATE = "docs/onboarding/start.md"

    # Builds the standard onboarding surface rooted at `root` (the repo/gem root),
    # wiring the PUBLIC_DOCS allowlist + start.md template. The three composition roots
    # (minimal wiring, DSL serve, deployment) pass their own stores/agents on top. A
    # doc whose file is absent (a slimmed-down gem) is simply dropped — never a boot
    # failure.
    def self.standard(root:, settings_store: nil, provider_store: nil, agents: nil)
      docs = PUBLIC_DOCS.each_with_object({}) do |(slug, rel), acc|
        path = File.join(root, rel)
        acc[slug] = path if File.file?(path)
      end
      new(template_path: File.join(root, TEMPLATE), docs: docs,
          settings_store: settings_store, provider_store: provider_store, agents: agents)
    end

    def initialize(template_path:, docs: {}, settings_store: nil, provider_store: nil, agents: nil)
      @template_path = template_path
      @docs = docs || {}
      @settings_store = settings_store
      @provider_store = provider_store
      @agents = agents # callable -> [Hash] | nil
    end

    # The onboarding skill (raw markdown), with the live base url interpolated so the
    # coding agent knows where to fetch the models list and docs. Read on each request
    # (the file is small and this surface is low-traffic) — editing start.md needs no
    # restart.
    def start_md(base_url:)
      base = normalize_base(base_url)
      substitute(File.read(@template_path), base)
    end

    # Machine-readable model catalog. Everything a coding agent needs to write a valid
    # `model`/`provider` line, and nothing secret. Sources that are absent (nil store)
    # simply drop their key — a fresh DSL serve still returns a coherent document
    # (served agents + thinking levels + whatever default is set).
    def models_json(base_url:)
      base = normalize_base(base_url)
      settings = @settings_store&.get || {}
      {
        schema_version: MODELS_SCHEMA_VERSION,
        base_url: base,
        responses_url: "#{base}/v1/responses",
        default: default_model(settings),
        fallbacks: fallback_models(settings),
        utility_model: presence(settings["utility_model"]),
        thinking_levels: ModelSelection::THINKING_LEVELS,
        providers: providers,
        agents: served_agents
      }.compact
    end

    # The public docs index (name + title + fetchable raw-markdown url). Drives
    # discovery: a coding agent lists this, then GETs the ones it needs.
    def docs_index(base_url:)
      base = normalize_base(base_url)
      @docs.keys.sort.map do |slug|
        { name: slug, title: doc_title(slug), url: "#{base}/docs/#{slug}.md" }
      end
    end

    # Raw markdown for one public doc, by slug. nil = unknown slug (the transport 404s).
    # No path traversal is possible: `slug` must be a KEY of the injected allowlist.
    #
    # The Jekyll frontmatter the docs site needs (title/parent/nav_order — the same
    # files ARE the site's pages) is STRIPPED here: a coding agent asked for the prose,
    # not for sidebar metadata, and this keeps the response byte-identical to what it
    # was before the site existed.
    def doc(slug)
      read_doc(slug)&.sub(FRONTMATTER, "")
    end

    private

    # Leading YAML block, plus the blank line after it, so the body still starts at
    # its `# Heading`. Same shape SkillCatalog accepts.
    FRONTMATTER = /\A---\s*\n(.*?)\n---\s*\n+/m
    private_constant :FRONTMATTER

    # Whole file, frontmatter included. nil = unknown slug or a file that vanished.
    def read_doc(slug)
      path = @docs[slug.to_s]
      return nil if path.nil? || !File.file?(path)

      File.read(path)
    end

    def substitute(text, base)
      text
        .gsub("{{BASE_URL}}", base)
        .gsub("{{MODELS_URL}}", "#{base}/models.json")
        .gsub("{{DOCS_URL}}", "#{base}/docs")
    end

    # default_model/default_provider -> { model:, provider: } | nil (nothing set).
    def default_model(settings)
      model = presence(settings["default_model"])
      return nil if model.nil?

      { model: model, provider: presence(settings["default_provider"]) }.compact
    end

    # Platform fallback chain as ["provider/model" | "model", …]; blank entries dropped.
    def fallback_models(settings)
      Array(settings["fallback_models"]).filter_map { |entry| presence(entry) }
    end

    # Providers a coding agent can target, from the MASKED store view: slug + the
    # model ids. Deliberately NO base_url / auth / key — model ids and slugs are all
    # that a `model`/`provider` line needs, and nothing here is a secret.
    def providers
      return nil if @provider_store.nil?

      @provider_store.all.map do |rec|
        { slug: rec["api"].to_s, models: Array(rec["models"]).map(&:to_s) }
      end
    end

    # Agents already served by THIS insika — over the drop-in API the `model` field
    # is the agent id, so this is the list of ids a client can call right now.
    def served_agents
      list = @agents.respond_to?(:call) ? Array(@agents.call) : nil
      return nil if list.nil? || list.empty?

      list.map do |a|
        { id: a[:id].to_s, model: presence(a[:model]), provider: presence(a[:provider]),
          description: presence(a[:description]) }.compact
      end
    end

    # Frontmatter `title` (what the site's sidebar shows — one source for both
    # surfaces), else the first markdown heading, else the humanized slug.
    def doc_title(slug)
      raw = read_doc(slug)
      front = raw&.match(FRONTMATTER)
      title = front && presence(Frontmatter.parse(front[1])["title"])
      return title if title

      heading = raw&.lines&.find { |l| l.start_with?("# ") }
      heading ? heading.sub(/\A#\s*/, "").strip : slug.tr("-_", "  ").capitalize
    end

    def normalize_base(base_url) = base_url.to_s.sub(%r{/+\z}, "")
    def presence(value) = Insika::Coercion.presence(value)
  end
end
