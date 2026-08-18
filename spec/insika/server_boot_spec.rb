# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/insika/dsl/server_boot"

# The judge button on /studio/parity must reach a registered command under
# Insika.serve — the deployment bus registers the same one in
# config/deployment.rb; a page answering "unknown command" would make the OSS
# root a second-class citizen.
RSpec.describe Insika::DSL::ServerBoot do
  CRITERION = Insika::Parity::Criterion.load(File.expand_path("../fixtures/parity/criterion.md", __dir__))

  BootRecordingBus = Struct.new(:registered) do
    def register(name, handler)
      registered << [name, handler]
    end
  end

  FakeGraph = Struct.new(:bus, :shadow_pair_store, :event_stream)
  FakeRuntime = Struct.new(:graph, :components) do
    def component(name) = components.fetch(name)
  end

  def boot(runtime)
    described_class.new(runtime, port: 9292, host: "127.0.0.1", token: "t")
  end

  def graph_and_runtime
    backend = Insika::Stores::Memory.new
    graph = FakeGraph.new(BootRecordingBus.new([]),
                          Insika::ShadowPairStore.new(store: backend),
                          Insika::EventStream.new)
    settings = Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend))
    [graph, FakeRuntime.new(graph, { settings_store: settings })]
  end

  def boot_with_criterion
    graph, runtime = graph_and_runtime
    b = boot(runtime)
    b.instance_variable_get(:@builder).instance_variable_set(:@criterion, CRITERION)
    [b, graph]
  end

  it "registers :judge_shadow_pairs on the bus once the criterion is loaded" do
    b, graph = boot_with_criterion
    b.send(:register_parity_commands)

    name, handler = graph.bus.registered.first
    expect(name).to eq(:judge_shadow_pairs)
    expect(handler).to be_a(Insika::Commands::JudgeShadowPairs)
    expect(handler.instance_variable_get(:@shadow_pairs)).to eq(graph.shadow_pair_store)
  end

  it "registers nothing without a criterion — no shadow, no fake judge" do
    graph, runtime = graph_and_runtime
    boot(runtime).send(:register_parity_commands)
    expect(graph.bus.registered).to be_empty
  end
end
