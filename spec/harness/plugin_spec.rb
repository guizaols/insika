# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Plugin do
  before { described_class.reset_announced! }
  after { described_class.reset_announced! }

  it "announce acumula na ordem de chamada" do
    described_class.announce("/a")
    described_class.announce("/b")
    expect(described_class.announced_roots).to eq(["/a", "/b"])
  end

  it "announce deduplica o mesmo root" do
    described_class.announce("/a")
    described_class.announce("/a")
    expect(described_class.announced_roots).to eq(["/a"])
  end

  it "announce expande path relativo para absoluto" do
    root = described_class.announce("plugins")
    expect(root).to eq(File.expand_path("plugins"))
    expect(described_class.announced_roots).to eq([File.expand_path("plugins")])
  end

  it "announced_roots devolve cópia congelada (acumulador intacto)" do
    described_class.announce("/a")
    frozen = described_class.announced_roots
    expect(frozen).to be_frozen
    expect { frozen << "/b" }.to raise_error(FrozenError)
    expect(described_class.announced_roots).to eq(["/a"])
  end

  it "reset_announced! esvazia o acumulador" do
    described_class.announce("/a")
    described_class.reset_announced!
    expect(described_class.announced_roots).to eq([])
  end
end
