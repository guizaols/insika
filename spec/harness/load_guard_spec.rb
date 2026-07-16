# frozen_string_literal: true

require "spec_helper"
require "open3"

# D9: o núcleo (lib/) não requer ruby_llm em load-time (os requires no
# Executor/LoadSkill são lazy, doc 03 §7). Como a gem agora vive sempre no
# bundle, a regra de testabilidade vira um teste: carregar o núcleo NÃO pode
# arrastar RubyLLM.
RSpec.describe "load-time guard (D9)" do
  it "require \"harness\" não carrega RubyLLM" do
    root = File.expand_path("../..", __dir__)
    script = 'require "harness"; exit(defined?(RubyLLM) ? 1 : 0)'
    _out, err, status = Open3.capture3("ruby", "-I#{File.join(root, "lib")}", "-e", script)

    expect(status.exitstatus).to eq(0), "require \"harness\" carregou RubyLLM (D9 violado): #{err}"
  end

  # Mesma disciplina para o OTEL (Fase 6): a Telemetry só puxa a gem lazy em
  # setup (opt-in). Carregar o núcleo NÃO pode arrastar OpenTelemetry.
  it "require \"harness\" não carrega OpenTelemetry" do
    root = File.expand_path("../..", __dir__)
    script = 'require "harness"; exit(defined?(OpenTelemetry) ? 1 : 0)'
    _out, err, status = Open3.capture3("ruby", "-I#{File.join(root, "lib")}", "-e", script)

    expect(status.exitstatus).to eq(0), "require \"harness\" carregou OpenTelemetry (opt-in violado): #{err}"
  end
end
