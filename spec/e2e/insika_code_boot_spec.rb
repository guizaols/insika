# frozen_string_literal: true

require "spec_helper"
require "open3"

# Regression guard for the insika-code EXAMPLE wiring. `examples/insika-code/
# boot.rb` builds the full object graph (engine + plugin + profile + Server::App)
# by consuming the core as a library — but nothing else exercises it, so when the
# core's constructors change (e.g. G6/#93 slimming Server::App to a pure /v1+/a2a
# transport, dropping checkpoint_store/catalogs/registries) the example silently
# rots into an ArgumentError at boot.
#
# Booting in a SUBPROCESS keeps it hermetic: the example defines top-level
# constants, mutates ENV, and registers plugin tools into fresh registries — none
# of which should leak into the rest of the suite.
RSpec.describe "insika-code example boots", :smoke do
  it "constructs the full wiring (engine + plugin + profile + Server::App) without error" do
    repo_root = File.expand_path("../..", __dir__)
    script = 'require "./examples/insika-code/boot"; ' \
             'raise "no app" unless InsikaCodeApp::Wiring::APP.is_a?(Insika::Server::App); ' \
             'print "BOOT OK"'
    out, status = Open3.capture2e("ruby", "-Ilib", "-e", script, chdir: repo_root)

    expect(status.exitstatus).to eq(0), "boot failed:\n#{out}"
    expect(out).to include("BOOT OK")
  end
end
