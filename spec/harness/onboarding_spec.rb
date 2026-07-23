# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Item 20 / §5.6 — the LLM-first onboarding surface (start.md + models.json + docs).
RSpec.describe Harness::Onboarding do
  # Minimal store doubles: the class only ever READS `get` / `all`.
  def settings_double(get)
    Class.new { def initialize(h) = (@h = h); def get = @h }.new(get)
  end

  def provider_double(all)
    Class.new { def initialize(a) = (@a = a); def all = @a }.new(all)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      @template = File.join(dir, "start.md")
      File.write(@template, "base={{BASE_URL}} models={{MODELS_URL}} docs={{DOCS_URL}}")
      @readme = File.join(dir, "README.md")
      File.write(@readme, "# Harness\n\nhello docs\n")
      example.run
    end
  end

  def build(**overrides)
    described_class.new(
      template_path: @template, docs: { "readme" => @readme }, **overrides
    )
  end

  describe "#start_md" do
    it "interpolates the live base url into the template links" do
      md = build.start_md(base_url: "https://h.example.com")

      expect(md).to eq(
        "base=https://h.example.com " \
        "models=https://h.example.com/models.json " \
        "docs=https://h.example.com/docs"
      )
    end

    it "strips a trailing slash from the base so links never double up" do
      md = build.start_md(base_url: "https://h.example.com/")
      expect(md).to include("models=https://h.example.com/models.json")
    end
  end

  describe "#models_json" do
    it "carries the thinking levels and base even with no stores" do
      json = build.models_json(base_url: "http://localhost:9292")

      expect(json[:schema_version]).to eq(described_class::MODELS_SCHEMA_VERSION)
      expect(json[:base_url]).to eq("http://localhost:9292")
      expect(json[:responses_url]).to eq("http://localhost:9292/v1/responses")
      expect(json[:thinking_levels]).to eq(Harness::ModelSelection::THINKING_LEVELS)
      # absent sources drop their keys entirely
      expect(json).not_to have_key(:default)
      expect(json).not_to have_key(:providers)
      expect(json).not_to have_key(:agents)
    end

    it "surfaces the platform default, fallbacks and utility model from settings" do
      settings = settings_double(
        "default_model" => "deepseek-chat", "default_provider" => "deepseek",
        "fallback_models" => ["openai/gpt-4o", "  ", "deepseek-reasoner"],
        "utility_model" => "deepseek-chat"
      )
      json = build(settings_store: settings).models_json(base_url: "http://x")

      expect(json[:default]).to eq(model: "deepseek-chat", provider: "deepseek")
      expect(json[:fallbacks]).to eq(["openai/gpt-4o", "deepseek-reasoner"])
      expect(json[:utility_model]).to eq("deepseek-chat")
    end

    it "lists providers with slug + model ids only — never keys or urls" do
      providers = provider_double([
        { "api" => "deepseek", "base_url" => "https://api.deepseek.com",
          "auth_header" => "Authorization", "api_key" => "__OCULTO__",
          "models" => %w[deepseek-chat deepseek-reasoner] }
      ])
      json = build(provider_store: providers).models_json(base_url: "http://x")

      expect(json[:providers]).to eq([{ slug: "deepseek", models: %w[deepseek-chat deepseek-reasoner] }])
      # no secret / connection detail leaks in the providers payload (the top-level
      # base_url is the harness's OWN url, which is fine).
      expect(JSON.generate(json[:providers])).not_to match(/OCULTO|base_url|auth_header|api_key/)
    end

    it "lists the served agents (their id is the /v1/responses model)" do
      agents = -> { [{ id: "bia", model: "deepseek-chat", provider: "deepseek" }] }
      json = build(agents: agents).models_json(base_url: "http://x")

      expect(json[:agents]).to eq([{ id: "bia", model: "deepseek-chat", provider: "deepseek" }])
    end

    it "omits the agents key when the callable yields an empty list" do
      json = build(agents: -> { [] }).models_json(base_url: "http://x")
      expect(json).not_to have_key(:agents)
    end
  end

  describe "docs" do
    it "indexes the allowlisted docs with a title from the first heading" do
      index = build.docs_index(base_url: "http://x")

      expect(index).to eq([{ name: "readme", title: "Harness", url: "http://x/docs/readme.md" }])
    end

    it "serves a known doc as raw markdown" do
      expect(build.doc("readme")).to eq("# Harness\n\nhello docs\n")
    end

    it "returns nil for an unknown slug (no filesystem traversal is possible)" do
      expect(build.doc("secret")).to be_nil
      expect(build.doc("../README")).to be_nil
    end
  end

  describe ".standard" do
    it "wires the repo's start.md template and public docs, dropping absent files" do
      onboarding = described_class.standard(root: @root)

      # Only the docs whose files exist under this root are wired.
      index = onboarding.docs_index(base_url: "http://x")
      expect(index.map { |d| d[:name] }).to eq(["readme"])
      expect(onboarding.doc("deploy")).to be_nil # DEPLOY.md absent in the tmp root
    end

    it "never includes an internal (gitignored) doc in the allowlist" do
      slugs = described_class::PUBLIC_DOCS.keys
      expect(slugs).not_to include("followup", "translation-tracker", "handoff-techspec")
    end
  end

  describe "the shipped repo template + docs" do
    it "the real start.md and every PUBLIC_DOCS file exist and render" do
      root = File.expand_path("../..", __dir__)
      onboarding = described_class.standard(root: root)

      md = onboarding.start_md(base_url: "https://harness.example")
      expect(md).to include("https://harness.example/models.json")
      expect(md).not_to include("{{") # no un-substituted placeholder leaks

      # all shipped public docs resolve to real files
      described_class::PUBLIC_DOCS.each_key do |slug|
        expect(onboarding.doc(slug)).to be_a(String), "missing public doc: #{slug}"
      end
    end
  end
end
