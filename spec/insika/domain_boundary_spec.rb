# frozen_string_literal: true

require "spec_helper"

#   — the domain boundary is the PAYLOAD, and it is enforced by one
# selection function: `Insika::Packaging.payload_files` is what the gemspec
# ships, so "what the gem contains" is a fact the suite asserts on, never a
# prose promise. Three mechanical checks:
#
#   (a) the selection excludes every domain directory (deploy/ packs/ examples/
#       plugins/ evals/ scripts/ spec/) — even a TRACKED pack cannot ship;
#   (b) the shipped pt-BR content is confined to the named allowlist (the
#       removable safety corpora) plus the docs' neutral
#       references (the pt-BR customer-message examples the docs teach) and
#       the agent form's field-hint examples (the same class of content);
#   (c) the demo persona name ("bia") ships nowhere — the rename pass (C7)
#       made this green.
#
  # Anything else that ships domain content must join the allowlist WITH a
  # written justification here. Expected result: the list stays at its entries.
  # (The yardstick is best-effort: it catches literal pt-BR strings, so the
  # corpus data with bracket-character regexes like `voc[êe]` is named here by
  # the inventory, not by the token scan.)
RSpec.describe "the domain boundary " do
  let(:payload) { Insika::Packaging.payload_files }

  # The ONLY payload files that may carry pt-BR domain content, each with its
  # justification (the "justified in writing" gate):
  #
  #   lib/insika/safety/corpus.rb         — the shipped guardrail corpus DATA
  #                                         (C2/D2); removable via
  #                                         guardrails.corpora.languages.
  #   lib/insika/safety/safe_responses.rb — pt-BR neutral fallback replies;
  #                                         removable via guardrails.responses.
  #   lib/insika/packaging.rb             — NOT domain content: it holds the
  #                                         token TABLE the audit itself scans
  #                                         with (the yardstick cannot be
  #                                         measured by its own measure).
  #
  # (Safety::Detectors is NOT on the list: since C2 it is the compiler, not
  # the data — the patterns live in corpus.rb, so it scores clean and the
  # generic rule covers it.)
  #
  # The allowlist is honest in both directions: every entry MUST match the
  # yardstick (a file that stops carrying pt-BR leaves the list), and no file
  # outside it may match.
  ALLOWLIST = {
    "lib/insika/safety/corpus.rb"         => "the shipped guardrail corpus data (C2) — cleared via guardrails.corpora",
    "lib/insika/safety/safe_responses.rb" => "pt-BR neutral fallback replies — cleared via guardrails.responses",
    "lib/insika/packaging.rb"             => "the audit's own token table (see the allowlist comment)",
    "lib/insika/studio/views/_agent_tab_config.erb" => "the agent config form's EXAMPLE placeholder — the default cancel-keyword " \
                                                       "('não quero mais contato') shown as the field's hint, data-like like the " \
                                                       "docs' neutral references, not engine vocabulary (was agent_detail.erb " \
                                                       "until the RFC-0041 tab-partials split)"
  }.freeze

  DOMAIN_DIRS = %w[deploy/ packs/ examples/ plugins/ evals/ scripts/ spec/].freeze

  # The docs teach pt-BR customer-message EXAMPLES (data, like the bilingual
  # safety suite)— the "docs' neutral references". The audit strips
  # fenced code blocks, inline code spans and short quoted examples before the
  # token scan, so a doc that teaches "queria saber do pedido" in a code block
  # stays green while prose with domain vocabulary fails.
  def neutralized_md(path)
    File.read(path)
        .gsub(/```.*?```\n?/m, "")          # fenced code blocks
        .gsub(/`[^`\n]*`/, "")               # inline code spans
        .gsub(/"[^"]{0,80}"/m, "")           # short quoted examples (citations)
  end

  describe "the selection is the boundary" do
    it "ships only lib/ + docs/ + the four root files" do
      allowed = ->(f) { f.start_with?("lib/", "docs/") || %w[README.md LICENSE CHANGELOG.md bin/insika bin/insika-router].include?(f) }
      expect(payload).to all(satisfy(&allowed))
    end

    it "excludes every domain directory — a tracked pack cannot ship" do
      offenders = payload.select { |f| DOMAIN_DIRS.any? { |d| f.start_with?(d) } }
      expect(offenders).to be_empty, "domain paths in the payload: #{offenders.join(", ")}"
    end

    it "excludes the studio JS toolchain and the docs' own Gemfile/config" do
      excluded = %w[docs/Gemfile docs/Gemfile.lock docs/_config.yml
                    lib/insika/studio/README.md lib/insika/studio/package.json
                    lib/insika/studio/package-lock.json lib/insika/studio/tailwind.config.js]
      expect(payload).not_to include(*excluded)
      expect(payload).to all(satisfy { |f| !f.include?("assets/src/") && !f.include?("studio/test/") })
      expect(payload).to all(satisfy { |f| !f.include?("node_modules") })
    end
  end

  describe "the allowlist holds (the shipped pt-BR content is confined)" do
    it "every allowlisted file actually carries pt-BR — a clean file leaves the list" do
      ALLOWLIST.each_key do |f|
        expect(Insika::Packaging.domain_content?(f)).to be(true),
                                                        "#{f} no longer matches the yardstick — remove it from the allowlist"
      end
    end

    it "no lib file OUTSIDE the allowlist ships pt-BR domain content" do
      offenders = payload.grep(%r{\Alib/}).reject { |f| ALLOWLIST.key?(f) }
                         .select { |f| Insika::Packaging.domain_content?(f) }
      expect(offenders).to be_empty,
                           "lib files with pt-BR domain content (join the allowlist WITH a justification, or fix): " \
                           "#{offenders.join(", ")}"
    end
  end

  describe "the docs' neutral references" do
    it "the persona name ships nowhere — no bia in any payload file" do
      offenders = payload.select { |f| Insika::Packaging.persona_content?(f) }
      expect(offenders).to be_empty, "the demo persona name is still in the payload: #{offenders.join(", ")}"
    end

    it "docs prose carries no domain vocabulary outside its examples (code spans/quotes)" do
      offenders = payload.grep(/\.md\z/).select do |f|
        neutralized_md(f).match?(Insika::Packaging::PT_BR_VOCABULARY)
      end
      expect(offenders).to be_empty,
                           "docs prose with domain vocabulary outside examples (quote it or reword): " \
                           "#{offenders.join(", ")}"
    end

    it "non-ruby, non-markdown payload files carry no domain content (the studio views/JS included)" do
      offenders = payload.reject { |f| f.end_with?(".rb", ".md") }
                         .reject { |f| ALLOWLIST.key?(f) } # the named exception is the exception everywhere
                         .select { |f| Insika::Packaging.domain_content?(f) }
      expect(offenders).to be_empty, "domain content in: #{offenders.join(", ")}"
    end
  end

  it "the gemspec ships exactly the same selection — the two never drift" do
    spec = Gem::Specification.load(File.expand_path("../../insika.gemspec", __dir__))
    expect(spec.files.sort).to eq(payload.sort)
  end

  # Found live (2026-08-21): a Railway/Docker build failed on `bundle install`
  # with "cannot load such file -- lib/insika/packaging" — RFC-0036 added a
  # require_relative to the gemspec but the Dockerfile's builder stage (which
  # COPYs only Gemfile*/insika.gemspec + a few lib/insika/*.rb files BEFORE
  # `bundle install`, for layer caching) was never updated to match. Bundler
  # evaluates the gemspec, so every file it require_relative's must exist in
  # that early, partial build context — not just somewhere in the final image.
  it "the Dockerfile's builder stage COPYs every file the gemspec require_relative's before bundle install" do
    gemspec_source = File.read(File.expand_path("../../insika.gemspec", __dir__))
    required = gemspec_source.scan(%r{require_relative\s+"(lib/insika/[a-z_]+)"}).flatten.map { |f| "#{f}.rb" }
    expect(required).not_to be_empty # a canary against the regex itself going stale

    dockerfile = File.read(File.expand_path("../../Dockerfile", __dir__))
    builder_stage = dockerfile[/FROM.*?RUN bundle install/m]
    copied = builder_stage.scan(%r{COPY (lib/insika/[a-z_]+\.rb) }).flatten

    missing = required - copied
    expect(missing).to be_empty,
                        "gemspec require_relative's #{missing.join(', ')} but the Dockerfile builder stage " \
                        "never COPYs it before `bundle install` — add `COPY <file> <file>` there"
  end
end
