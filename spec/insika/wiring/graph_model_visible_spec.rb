# frozen_string_literal: true

require "spec_helper"

# INSIKA_MODEL_VISIBLE_TRACES=0 stops the executor from writing the full model
# request per turn (~80% of a turn's SQLite bytes); unset keeps it on.
RSpec.describe Insika::Wiring::Graph do
  it "records model-visible traces unless the env turns them off" do
    flag = ->(value) { described_class.model_visible_traces?(value.nil? ? {} : { "INSIKA_MODEL_VISIBLE_TRACES" => value }) }

    expect([nil, "1", "0", "false"].map(&flag)).to eq([true, true, false, false])
  end
end
