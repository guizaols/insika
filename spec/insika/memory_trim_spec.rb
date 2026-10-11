# frozen_string_literal: true

require "spec_helper"
require "insika/memory_trim"

RSpec.describe Insika::MemoryTrim do
  let(:in_flight) { [] }
  let(:executor) { double("executor", in_flight: in_flight) }
  let(:allocated) { [0] }
  let(:trims) { [] }

  def trimmer = described_class.new(executor: executor, trim: -> { trims << :trim }, allocated: -> { allocated[0] })

  it "trims once the worker is quiet and has allocated enough since the last trim" do
    t = trimmer
    allocated[0] = described_class::MIN_ALLOCATED
    expect(t.run_once).to be(true)
    expect(trims).to eq([:trim])
    expect(t.run_once).to be(false) # nothing allocated since
  end

  it "never trims while a turn is in flight" do
    t = trimmer
    allocated[0] = described_class::MIN_ALLOCATED
    in_flight << "task-1"
    expect(t.run_once).to be(false)
    expect(trims).to be_empty
  end

  it "skips a full GC when little was allocated" do
    t = trimmer
    allocated[0] = described_class::MIN_ALLOCATED - 1
    expect(t.run_once).to be(false)
  end

  it "is disabled without malloc_trim" do
    expect(described_class.new(executor: executor, trim: nil).start(parent: nil)).to be(false)
  end
end
