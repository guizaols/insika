# frozen_string_literal: true

# Loads the contract suite to ensure the file parses clean
# (the first real run against a backend is task 3).
require_relative "../../lib/insika/testing/store_contract"

RSpec.describe Insika::Store do
  # Incomplete backend: only includes the module, overrides nothing.
  subject(:incomplete) { Class.new { include Insika::Store }.new }

  it "raises NotImplementedError on #get" do
    expect { incomplete.get("s", "k") }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError on #set" do
    expect { incomplete.set("s", "k", 1) }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError on #delete" do
    expect { incomplete.delete("s", "k") }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError on #list" do
    expect { incomplete.list("s") }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError on #transaction" do
    expect { incomplete.transaction { 1 } }.to raise_error(NotImplementedError)
  end
end
