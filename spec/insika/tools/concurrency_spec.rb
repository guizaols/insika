# frozen_string_literal: true

require "spec_helper"
require "async"
require "insika/tools/concurrency"

# RFC-0010 §B1: the aggregator-tool helper — fan out N I/O calls inside one tool
# and gather the results in order.
RSpec.describe Insika::Tools::Concurrency do
  describe ".gather" do
    it "returns results IN ORDER regardless of completion order" do
      out = described_class.gather(-> { "a" }, -> { "b" }, -> { "c" })
      expect(out).to eq(%w[a b c])
    end

    it "runs the blocks CONCURRENTLY (overlapping waits, not serial)" do
      # 3 blocks that each 'sleep' 20ms on the reactor: serial would be ~60ms,
      # concurrent ~20ms. Assert well under the serial sum.
      mono = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      started = mono.call
      described_class.gather(*Array.new(3) { -> { Async::Task.current.sleep(0.02) } })
      elapsed = mono.call - started
      expect(elapsed).to be < 0.05 # comfortably below 3×20ms serial
    end

    it "bounds concurrency to `max`" do
      live = 0
      peak = 0
      blocks = Array.new(6) do
        lambda do
          live += 1
          peak = [peak, live].max
          Async::Task.current.sleep(0.01)
          live -= 1
        end
      end
      described_class.gather(*blocks, max: 2)
      expect(peak).to be <= 2
    end

    it "returns [] for no blocks" do
      expect(described_class.gather).to eq([])
    end

    it "propagates an exception from a block (does not swallow)" do
      expect { described_class.gather(-> { 1 }, -> { raise "boom" }) }.to raise_error(/boom/)
    end
  end
end
