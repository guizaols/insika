# frozen_string_literal: true

require_relative "lib/insika/version"

Gem::Specification.new do |spec|
  spec.name = "insika"
  spec.version = Insika::VERSION
  spec.authors = ["Guilherme Lages Santos"]
  spec.email = ["guilherme@devconnit.com"]

  spec.summary = "A Ruby runtime for LLM agents in production."
  spec.description = "A durable, resumable turn pipeline behind an " \
                     "OpenAI-Responses-compatible HTTP API, plus a web control UI. " \
                     "Tools, skills, cross-session memory, per-agent policy, " \
                     "content-safety guardrails — one gem, five shapes: reply " \
                     "in-process, serve, rack_app mounted, embed(backend:)."
  spec.homepage = "https://github.com/guizaols/insika"
  spec.license = "MIT"
  # Recommended/tested runtime is `.ruby-version` (3.4.x); the floor stays
  # permissive so the gem is consumable on older interpreters (3.2 is EOL).
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://guizaols.github.io/insika/",
    "rubygems_mfa_required" => "true"
  }

  # ONE gem: lib/ — engine + server + Studio (assets/dist
  # ships, the JS toolchain does not) — plus the public docs the onboarding
  # surface serves (/docs, start.md). config/, deploy/, Dockerfile and the
  # examples stay checkout-only: the reference deployment is not the gem.
  #
  # The list comes from `git ls-files` (so an UNTRACKED lib file never ships —
  # see docs/RELEASING.md), falling back to a glob where there is no .git (the
  # Docker build context excludes it).
  spec.files = Dir.chdir(__dir__) do
    tracked = `git ls-files -z 2>/dev/null`.split("\x0")
    tracked = Dir.glob("{lib,docs}/**/*", File::FNM_DOTMATCH).reject { |f| File.directory?(f) } +
              %w[README.md LICENSE CHANGELOG.md bin/insika] if tracked.empty?
    tracked.select do |file|
      file.start_with?("lib/", "docs/") ||
        %w[README.md LICENSE CHANGELOG.md bin/insika].include?(file)
    end.reject do |file|
      file.include?("node_modules") ||
        file.start_with?("lib/insika/studio/test/", "lib/insika/studio/assets/src/") ||
        %w[docs/Gemfile docs/Gemfile.lock docs/_config.yml
           lib/insika/studio/README.md lib/insika/studio/package.json
           lib/insika/studio/package-lock.json lib/insika/studio/tailwind.config.js].include?(file)
    end
  end
  spec.bindir = "bin"
  spec.executables = ["insika"]
  spec.require_paths = ["lib"]

  # Runtime = what a turn and `serve` need. OpenTelemetry stays
  # OUT of this set: Telemetry requires it lazily, only when INSIKA_OTEL is on —
  # an adopter who wants it adds the gems (the reference deployment's Gemfile
  # does exactly that). The load guard (spec/insika/load_guard_spec.rb) is the
  # test that nothing below drags ruby_llm/roda/falcon in at require time.
  spec.add_dependency "async", "~> 2.0"       # reactor, SQLite write semaphore
  spec.add_dependency "ruby_llm", ">= 1.15"   # before_tool_call/after_tool_result need 1.15+
  spec.add_dependency "falcon", "~> 0.55"     # async server
  spec.add_dependency "sqlite3", "~> 2.0"     # the durable Store backend
  spec.add_dependency "rack", "~> 3.0"        # transport
  spec.add_dependency "roda", "~> 3.85"       # the Studio (control UI)
  spec.add_dependency "tilt", "~> 2.8"        # template rendering (Studio)
  spec.add_dependency "erubi", "~> 1.13"      # ERB with automatic escaping (XSS-safe)

  spec.add_development_dependency "rspec"
end
