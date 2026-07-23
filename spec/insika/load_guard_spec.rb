# frozen_string_literal: true

require "spec_helper"
require "open3"

# D9: the core (lib/) does not require ruby_llm at load-time (the requires in
# Executor/LoadSkill are lazy, doc 03 §7). Since the gem now always lives in the
# bundle, the testability rule becomes a test: loading the core MUST NOT drag in
# RubyLLM.
RSpec.describe "load-time guard (D9)" do
  it "require \"insika\" does not load RubyLLM" do
    root = File.expand_path("../..", __dir__)
    script = 'require "insika"; exit(defined?(RubyLLM) ? 1 : 0)'
    _out, err, status = Open3.capture3("ruby", "-I#{File.join(root, "lib")}", "-e", script)

    expect(status.exitstatus).to eq(0), "require \"insika\" loaded RubyLLM (D9 violated): #{err}"
  end

  # Same discipline for OTEL (Phase 6): Telemetry only pulls the gem lazily in
  # setup (opt-in). Loading the core MUST NOT drag in OpenTelemetry.
  it "require \"insika\" does not load OpenTelemetry" do
    root = File.expand_path("../..", __dir__)
    script = 'require "insika"; exit(defined?(OpenTelemetry) ? 1 : 0)'
    _out, err, status = Open3.capture3("ruby", "-I#{File.join(root, "lib")}", "-e", script)

    expect(status.exitstatus).to eq(0), "require \"insika\" loaded OpenTelemetry (opt-in violated): #{err}"
  end
end
