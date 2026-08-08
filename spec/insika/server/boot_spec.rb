# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/boot"

# doc 07 §7: order plugins→stores→recovery→(app). App is only returned AFTER
# recovery. Corrupted store at boot -> aborts (does not return app).
RSpec.describe Insika::Server::Boot do
  # Double wiring: records the call order in a shared array.
  class WiringDouble
    attr_reader :calls

    def initialize(calls, recovery:, app: :the_app)
      @calls = calls
      @recovery = recovery
      @app = app
    end

    def load_plugins = @calls << :plugins
    def build_stores = @calls << :stores
    def recovery = @recovery
    def app
      @calls << :app
      @app
    end
  end

  RecoveryDouble = Struct.new(:calls, :result, :error) do
    def run
      calls << :recovery
      raise error if error

      result || { resumed: [], failed: [] }
    end
  end

  it "runs plugins -> stores -> recovery and only then returns the app" do
    calls = []
    wiring = WiringDouble.new(calls, recovery: RecoveryDouble.new(calls, { resumed: [], failed: [] }, nil))

    app = described_class.new(wiring, logger: nil).call

    expect(calls).to eq(%i[plugins stores recovery app])
    expect(app).to eq(:the_app)
  end

  it "recovery raises StoreError -> Boot aborts and does NOT return the app" do
    calls = []
    boom = RecoveryDouble.new(calls, nil, Insika::StoreError.new("db corrompido"))
    wiring = WiringDouble.new(calls, recovery: boom)

    expect { described_class.new(wiring, logger: nil).call }.to raise_error(Insika::StoreError)
    expect(calls).not_to include(:app) # aborted before releasing the app to the listen
  end

  it "unrecoverable task (failed) does not bring down the boot" do
    calls = []
    wiring = WiringDouble.new(calls, recovery: RecoveryDouble.new(calls, { resumed: [], failed: ["t-1"] }, nil))

    app = described_class.new(wiring, logger: nil).call

    expect(app).to eq(:the_app)
    expect(calls).to eq(%i[plugins stores recovery app])
  end

  it "wraps recovery in Sync when there is no current reactor" do
    calls = []
    recovery = RecoveryDouble.new(calls, { resumed: [], failed: [] }, nil)
    wiring = WiringDouble.new(calls, recovery: recovery)

    # Outside any Async: should not raise (Boot creates the reactor).
    expect { described_class.new(wiring, logger: nil).call }.not_to raise_error
    expect(calls).to include(:recovery)
  end

  # RFC-0016 A2: a serving arm that assembles its own Rack app around the wiring
  # (config.ru's URLMap with the Studio) injects it; recovery still runs first.
  it "app: override returns the injected app after recovery, without asking the wiring" do
    calls = []
    wiring = WiringDouble.new(calls, recovery: RecoveryDouble.new(calls, nil, nil))

    app = described_class.new(wiring, logger: nil, app: :urlmap).call

    expect(app).to eq(:urlmap)
    expect(calls).to eq(%i[plugins stores recovery]) # wiring.app never consulted
  end

  # RFC-0016 E2: the TASK sweep runs once per boot generation; a worker whose
  # claim lost skips it — but the delegation/channel sweeps still run (each of
  # their records claims for itself).
  describe "the sweep claim (claim_recovery_sweep)" do
    # WiringDouble + the claim + the per-record sweeps, recording everything.
    class ClaimWiringDouble < WiringDouble
      def initialize(calls, recovery:, claim:, app: :the_app)
        super(calls, recovery: recovery, app: app)
        @claim = claim
      end

      def claim_recovery_sweep
        @calls << :claim
        @claim
      end

      def recover_delegations = (@calls << :delegations) && { delivered: [] }
      def recover_channel_deliveries = (@calls << :channels) && { dispatched: [] }
    end

    it "claim won -> the task sweep runs" do
      calls = []
      wiring = ClaimWiringDouble.new(calls, recovery: RecoveryDouble.new(calls, nil, nil), claim: true)

      described_class.new(wiring, logger: nil).call

      expect(calls).to eq(%i[plugins stores claim recovery delegations channels app])
    end

    it "claim lost -> skips ONLY the task sweep; delegations and channels still sweep" do
      calls = []
      wiring = ClaimWiringDouble.new(calls, recovery: RecoveryDouble.new(calls, nil, nil), claim: false)

      app = described_class.new(wiring, logger: nil).call

      expect(calls).to eq(%i[plugins stores claim delegations channels app])
      expect(calls).not_to include(:recovery)
      expect(app).to eq(:the_app) # a skipped sweep is a normal boot, not an abort
    end

    it "a wiring without the claim sweeps unconditionally (single-process arms)" do
      calls = []
      wiring = WiringDouble.new(calls, recovery: RecoveryDouble.new(calls, nil, nil))

      described_class.new(wiring, logger: nil).call

      expect(calls).to include(:recovery)
    end
  end
end
