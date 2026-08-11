# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# The FS boundary is the always-on half of the sandbox primitive. This
# is the insika-code prototype's Workspace spec, ported verbatim to the core
# `Insika::Sandbox::Boundary` — the exact same escape guarantees must hold now
# that the boundary is a core primitive shared by every provider.
RSpec.describe Insika::Sandbox::Boundary do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  subject(:boundary) { described_class.new(@root) }

  describe "#resolve" do
    it "resolves a relative path to an absolute path inside the root" do
      expect(boundary.resolve("a/b.txt")).to eq(File.join(@root, "a/b.txt"))
    end

    it "normalizes '.' to the root" do
      expect(boundary.resolve(".")).to eq(@root)
    end

    it "blocks '..' traversal that escapes the root" do
      expect { boundary.resolve("../secret") }.to raise_error(described_class::Escape)
    end

    it "blocks an absolute path outside the root" do
      expect { boundary.resolve("/etc/passwd") }.to raise_error(described_class::Escape)
    end

    it "blocks an empty path" do
      expect { boundary.resolve("  ") }.to raise_error(described_class::Escape)
    end

    it "does not treat a sibling with the root as a prefix as inside (boundary)" do
      sibling = "#{@root}-evil"
      FileUtils.mkdir_p(sibling)
      expect { boundary.resolve(sibling) }.to raise_error(described_class::Escape)
    ensure
      FileUtils.remove_entry(sibling) if sibling && File.exist?(sibling)
    end

    it "blocks a symlink that points outside the root (symlink guard)" do
      outside = Dir.mktmpdir
      File.write(File.join(outside, "target.txt"), "secret")
      File.symlink(File.join(outside, "target.txt"), File.join(@root, "link.txt"))
      expect { boundary.resolve("link.txt") }.to raise_error(described_class::Escape)
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    it "on for_write, allows a not-yet-existing file whose parent is inside" do
      expect(boundary.resolve("new/file.txt", for_write: true))
        .to eq(File.join(@root, "new/file.txt"))
    end

    # Sandbox-escape regression: before the fix, resolve(for_write: true) only
    # vetted the STRING and the PARENT dir's realpath, never the final component.
    # A symlink under the root pointing outside would pass every check and a
    # subsequent File.write would FOLLOW it, clobbering a file outside the root.
    it "on for_write, rejects a final component that is a symlink pointing outside the root" do
      outside = Dir.mktmpdir
      external = File.join(outside, "victim.txt")
      File.write(external, "original")
      File.symlink(external, File.join(@root, "link.txt"))

      expect { boundary.resolve("link.txt", for_write: true) }
        .to raise_error(described_class::Escape, /symlink/)
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    it "on for_write, rejects a broken symlink whose (outside) target does not yet exist" do
      outside = Dir.mktmpdir
      # Dangling target: File.exist? is false, so only an lstat-based check catches it.
      File.symlink(File.join(outside, "does-not-exist.txt"), File.join(@root, "dangling.txt"))

      expect { boundary.resolve("dangling.txt", for_write: true) }
        .to raise_error(described_class::Escape, /symlink/)
    ensure
      FileUtils.remove_entry(outside) if outside
    end
  end

  describe "#relative" do
    it "renders the root as '.'" do
      expect(boundary.relative(@root)).to eq(".")
    end

    it "strips the root prefix" do
      expect(boundary.relative(File.join(@root, "x/y.rb"))).to eq("x/y.rb")
    end
  end

  it "fails fast when the root does not exist" do
    expect { described_class.new(File.join(@root, "nope")) }
      .to raise_error(described_class::Escape)
  end

  it "is aliased as Insika::Sandbox::Escape for ergonomic rescues" do
    expect(Insika::Sandbox::Escape).to be(described_class::Escape)
  end
end
