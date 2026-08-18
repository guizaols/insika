# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/insika/server/app"

# RFC-0036 C6 — the /v1 freeze is a DOC promise plus a drift pin: the frozen
# date in docs/API.md must equal the server gate's first known version. The
# two cannot drift: a release that bumps the gate without rewriting the
# promise (or vice-versa) fails here, before it ships. The gate's RUNTIME half
# (400 on unknown, known versions accepted) stays covered in server/app_spec.
RSpec.describe "the /v1 freeze pin (RFC-0036 C6)" do
  it "the gate's first known version is the doc's frozen-as date" do
    api_doc = File.read(File.expand_path("../../../docs/API.md", __dir__))
    frozen = api_doc[/\*\*Frozen as of:\s*([0-9-]+)\*\*/, 1]
    expect(frozen).not_to be_nil, "docs/API.md must carry a **Frozen as of:** line"

    gate = Insika::Server::App.const_get(:KNOWN_VERSIONS)
    expect(frozen).to eq(gate.first),
                       "docs/API.md says #{frozen.inspect} but the gate's first version is #{gate.first.inspect} — " \
                       "a breaking change needs a new Insika-Version entry AND a rewritten promise"
  end
end
