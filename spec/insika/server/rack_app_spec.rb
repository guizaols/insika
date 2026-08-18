# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/insika/server/rack_app"

# C1's boot refusal: shadow on without a frozen criterion refuses boot AT the
# composition root (D2 — "a number written after the experiment does not count"
# only because the machine refuses to run without it).
RSpec.describe Insika::Server::AppBuilder do
  KEYS = %w[INSIKA_RELAY_TOKEN INSIKA_RELAY_DELIVER_URL INSIKA_RELAY_SHADOW
            INSIKA_PARITY_CRITERION INSIKA_EGRESS_ALLOW_HTTP INSIKA_EGRESS_ALLOW_PRIVATE].freeze

  around do |ex|
    saved = KEYS.to_h { |k| [k, ENV[k]] }
    KEYS.each { |k| ENV.delete(k) }
    ex.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  let(:criterion_path) { File.expand_path("../../fixtures/parity/criterion.md", __dir__) }

  def builder
    handle = Insika.embed(backend: Insika::Stores::Memory.new) do
      agent "support" do
        instructions "You are helpful."
      end
    end
    described_class.new(handle, token: "tok")
  end

  def shadow_env
    ENV["INSIKA_RELAY_TOKEN"] = "relay-tok"
    ENV["INSIKA_RELAY_SHADOW"] = "1"
  end

  it "no shadow flag, no criterion — a normal boot never touches the file" do
    ENV["INSIKA_RELAY_TOKEN"] = "relay-tok"
    b = builder
    b.app
    expect(b.criterion).to be_nil
    expect(b.channels?).to be(true)
  end

  it "shadow + missing criterion -> ConfigError at boot, naming the path" do
    shadow_env
    ENV["INSIKA_PARITY_CRITERION"] = "/definitely/not/here.md"
    expect { builder.app }.to raise_error(Insika::ConfigError, %r{/definitely/not/here\.md})
  end

  it "shadow + a criterion with no yaml block -> ConfigError at boot" do
    shadow_env
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PARITY.md")
      File.write(path, "prose without a block\n")
      ENV["INSIKA_PARITY_CRITERION"] = path
      expect { builder.app }.to raise_error(Insika::ConfigError, /yaml/)
    end
  end

  it "shadow + valid criterion -> boots, mounts the relay, and stamps the delivery path with its sha" do
    shadow_env
    ENV["INSIKA_PARITY_CRITERION"] = criterion_path
    b = builder
    b.app

    expect(b.criterion).not_to be_nil
    expect(b.criterion.rule.window_days).to eq(7)
    expect(b.graph.channel_registry.find("relay")).to be_shadow
    expect(b.graph.channel_delivery.instance_variable_get(:@criterion_sha)).to eq(b.criterion.sha)
  end

  it "shadow + unset criterion -> ConfigError at boot (the criterion is never defaulted)" do
    shadow_env
    expect { builder.app }.to raise_error(Insika::ConfigError, /INSIKA_PARITY_CRITERION/)
  end
end
