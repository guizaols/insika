# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"

# Integration proof of the public benchmark. Shells out to the
# real script with tiny params so the internal seams it depends on stay honest:
# the DSL data_tool shape, the single `Executor#create_chat` override, and the
# INSIKA_TURN_TIMING split attached to the terminal event. HERMETIC: a clean env
# (no inherited INSIKA_*/HARNESS_*/keys) — the script forces the in-memory backend
# and never calls a provider, so a run needs no API key and touches no volume.
RSpec.describe "scripts/bench.rb" do
  let(:script) { File.expand_path("../../scripts/bench.rb", __dir__) }

  def run(*args, model_context_guard: false)
    base = { "INSIKA_DB" => nil, "HARNESS_DB" => nil, "DEEPSEEK_API_KEY" => nil, "ADMIN_TOKEN" => nil,
             "INSIKA_TURN_TIMING" => nil, "HARNESS_TURN_TIMING" => nil }
    guard = <<~RUBY
      require "ruby_llm"
      RubyLLM::Models.prepend(Module.new do
        def find(id, provider: nil, **options)
          raise "missing request model context" if id == "stub-model" && provider.nil?
          super(id, provider: provider, **options)
        end
      end)
      load ARGV.shift
    RUBY
    command = model_context_guard ? ["ruby", "-e", guard] : ["ruby"]
    out, err, status = Open3.capture3(base, *command, script, *args, unsetenv_others: false)
    [status.success? ? out : out + err, status]
  end

  it "runs every scenario provider-free with zero errors" do
    out, status = run("--iterations", "3", "--warmup", "1", "--concurrency", "2", "--waves", "1")
    expect(status).to be_success
    %w[greeting tool_call multi_turn].each do |name|
      expect(out).to match(/scenario: #{name}\s+\(errors: 0\)/)
    end
    expect(out).to include("provider-free")
  end

  it "emits a machine-readable JSON report with the timing split" do
    out, status = run("--scenario", "tool_call", "--iterations", "3", "--warmup", "1",
                      "--waves", "1", "--concurrency", "2", "--json")
    expect(status).to be_success
    report = JSON.parse(out)
    expect(report["engine"]).to include("insika")
    result = report.fetch("results").first
    expect(result["scenario"]).to eq("tool_call")
    expect(result["errors"]).to eq(0)
    # the prep/ttft/gen split proves INSIKA_TURN_TIMING flowed to the event.
    expect(result.dig("latency", "total", "p50")).to be_a(Numeric)
    expect(result.dig("latency", "prep")).to include("p50", "p95")
    expect(report["mode"]).to eq("stub")
    expect(result.dig("allocations", "total")).to be > 0
    expect(result.dig("allocations", "per_turn")).to be > 0
  end

  it "rejects an unknown scenario" do
    out, status = run("--scenario", "nope")
    expect(status).not_to be_success
    expect(out).to match(/--scenario must be one of/)
  end

  it "runs real RubyLLM streaming, two tool rounds and seeded history offline" do
    out, status = run("--ruby-llm", "--iterations", "2", "--warmup", "1",
                      "--waves", "1", "--concurrency", "2", "--history-turns", "4",
                      "--output-tokens", "3", "--json", model_context_guard: true)
    expect(status).to be_success, out
    report = JSON.parse(out)
    expect(report["mode"]).to eq("ruby_llm")
    expect(report["ruby_llm"]).to eq(Gem.loaded_specs.fetch("ruby_llm").version.to_s)
    report.fetch("results").each do |result|
      expect(result["errors"]).to eq(0), result.inspect
      expect(result.dig("latency", "total", "n")).to eq(2)
      expect(result.dig("allocations", "per_turn")).to be > 0
      activity = result.fetch("ruby_llm_activity")
      expect(activity["streamed_chunks"]).to eq(15)
      expect(activity["provider_calls"]).to eq(result["scenario"] == "tool_call" ? 15 : 5)
      expect(activity.fetch("tool_calls", 0)).to eq(result["scenario"] == "tool_call" ? 10 : 0)
      expect(activity["history_messages"]).to eq(result["scenario"] == "multi_turn" ? 20 : 0)
    end
  end

  it "--help prints the methodology header without running" do
    out, status = run("--help")
    expect(status).to be_success
    expect(out).to match(/NEUTRAL, REPRODUCIBLE, PROVIDER-FREE/)
  end
end
