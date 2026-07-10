# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::WorkflowRegistry do
  subject(:registry) { described_class.new }

  it "resolve um callable registrado por lambda" do
    registry.register("w", ->(input, context:, tools:) { [input, context, tools] })
    wf = registry.resolve("w")
    expect(wf.call("in", context: :ctx, tools: [])).to eq(["in", :ctx, []])
  end

  it "resolve um callable registrado por bloco factory" do
    registry.register("w") { ->(input, **) { "handled:#{input}" } }
    expect(registry.resolve("w").call("x")).to eq("handled:x")
  end

  it "herda duplicata (primeiro vence) e NotFound do genérico" do
    registry.register("w", -> {})
    expect { registry.register("w", -> {}) }.to output.to_stderr
    expect { registry.resolve("nope") }.to raise_error(Harness::NotFoundError)
  end
end
