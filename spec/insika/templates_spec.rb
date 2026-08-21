# frozen_string_literal: true

require "spec_helper"

# Insika::Templates — the RFC-0039 template gallery. Frontmatter parsing is
# pure (tested via .send, no filesystem); the roster tests below run against
# the REAL lib/insika/templates/ tree — this IS the E3 conformance spec RFC-
# 0039 §5 asks for: the roster is linted, not trusted.
RSpec.describe Insika::Templates do
  describe ".frontmatter (private, pure)" do
    def frontmatter(source) = described_class.send(:frontmatter, source)

    it "parses a # --- ... # --- comment block into a Hash" do
      source = <<~RUBY
        # frozen_string_literal: true

        # ---
        # title: Demo
        # trail: Starter
        # description: a thing
        # capabilities: a, b
        # studio: false
        # ---
        require "insika"
      RUBY
      meta = frontmatter(source)
      expect(meta).to eq("title" => "Demo", "trail" => "Starter", "description" => "a thing",
                          "capabilities" => "a, b", "studio" => false)
    end

    it "skips the magic comment and blank lines before looking for the block" do
      source = "# frozen_string_literal: true\n\n# ---\n# title: X\n# ---\n"
      expect(frontmatter(source)["title"]).to eq("X")
    end

    it "a file with no frontmatter block returns {}" do
      expect(frontmatter("# frozen_string_literal: true\nrequire \"insika\"\n")).to eq({})
    end
  end

  describe ".read" do
    it "raises NotFoundError for an unknown template" do
      expect { described_class.read("bogus-template") }.to raise_error(Insika::NotFoundError, /bogus-template/)
    end
  end

  describe ".evaluate" do
    it "raises NotFoundError for an unknown template" do
      expect { described_class.evaluate("bogus-template") }.to raise_error(Insika::NotFoundError, /bogus-template/)
    end

    it "two evaluations of the same template don't share local state (isolated eval)" do
      a = described_class.evaluate("travel-planner")
      b = described_class.evaluate("travel-planner")
      expect(a).not_to equal(b)
      expect(a.to_pack.config[:id]).to eq(b.to_pack.config[:id])
    end
  end

  # RFC-0039 §5 E3 — "the roster is linted, not trusted": iterates every REAL
  # template, one example per name (generated at load time — a broken new
  # template shows up as a named failure, not a generic loop assertion).
  describe "wave-1 roster (E3 conformance)" do
    it "ships all 6 wave-1 templates (one per trail, two for MCP)" do
      expect(described_class.names).to contain_exactly(
        "travel-planner", "research-analyst", "daily-digest", "review-panel", "repo-explorer", "browser-agent"
      )
    end

    described_class.names.each do |name|
      it "'#{name}' evaluates cleanly to schema-valid pack(s), with EVERY tool/mcp group covered by an allowlist, no secrets, only public hosts" do
        entry = Insika::Templates.read(name)
        expect(entry.title).not_to be_empty
        expect(entry.trail).not_to be_nil

        built = Insika::Templates.evaluate(name)
        packs = built.respond_to?(:to_packs) ? built.to_packs : [built.to_pack]

        packs.each do |pack|
          expect(pack.config[:id].to_s).not_to be_empty
          expect(pack.config[:model].to_s).not_to be_empty

          # Every data-tool the pack declares must be in THAT SAME pack's
          # tools_allow (data_tool auto-adds it — this catches a future
          # template that bypasses the DSL helper and hand-builds tools).
          pack.tools.each do |t|
            tool_name = (t["name"] || t[:name]).to_s
            expect(Array(pack.config[:tools_allow])).to include(tool_name)
          end
        end

        # Every mcp instance's group must be granted in SOME agent of the
        # pack(s) — the RFC-0040 gap this same PR fixed (mcp auto-adds it;
        # this is the regression net for the templates specifically).
        built.mcp_instances.each do |decl|
          group = "mcp:#{decl[:name]}"
          owner = packs.find { |p| Array(p.config[:tools_allow_groups]).include?(group) }
          expect(owner).not_to be_nil, "no agent in '#{name}' grants access to its own #{group} group"
        end

        # Only public hosts — an mcp url's/data-tool's target counts as a
        # declared external reference, same as RFC-0039 E3 requires.
        data_tool_urls = packs.flat_map { |p| p.tools.map { |t| (t["request"] || t[:request])&.[]("url") || (t["request"] || t[:request])&.[](:url) } }.compact
        mcp_urls = built.mcp_instances.select { |m| %w[http sse].include?(m[:transport].to_s) }.map { |m| m[:url] }
        (data_tool_urls + mcp_urls).each do |url|
          expect(Insika::EgressGuard.violation(url)).to be_nil, "'#{name}': #{url} is not a public HTTPS host"
        end

        # No hardcoded secret — a real-looking API key or bearer token
        # literal in the source (placeholders like "sk-..." in a comment/
        # printed run line are fine; a real-looking long token is not).
        source = File.read(Insika::Templates.agent_path(name))
        expect(source).not_to match(/sk-[a-zA-Z0-9]{16,}/)
        expect(source).not_to match(/Bearer [a-zA-Z0-9._-]{20,}/)
      end
    end
  end
end
