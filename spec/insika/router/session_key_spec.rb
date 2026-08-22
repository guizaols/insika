# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../../../lib/insika/router/session_key"

RSpec.describe Insika::Router::SessionKey do
  def body_for(hash)
    -> { hash }
  end

  it "extracts `user` from POST /v1/responses" do
    key = described_class.extract("POST", %w[v1 responses], body: body_for({ "user" => "sess-1" }))
    expect(key).to eq("sess-1")
  end

  it "extracts `user` from POST /v1/messages" do
    key = described_class.extract("POST", %w[v1 messages], body: body_for({ "user" => "sess-2" }))
    expect(key).to eq("sess-2")
  end

  it "extracts `session_id` from POST /channels/:id/messages" do
    key = described_class.extract("POST", %w[channels widget messages], body: body_for({ "session_id" => "sess-3" }))
    expect(key).to eq("sess-3")
  end

  it "extracts `session_id` from POST /channels/:id/events (Shape B webhook)" do
    key = described_class.extract("POST", %w[channels relay events], body: body_for({ "session_id" => "sess-4" }))
    expect(key).to eq("sess-4")
  end

  it "accepts symbol-keyed bodies too (a caller that parsed with symbolize_names)" do
    key = described_class.extract("POST", %w[v1 responses], body: body_for({ user: "sess-5" }))
    expect(key).to eq("sess-5")
  end

  it "round-robins (nil) a GET — no key, no body read" do
    reads = 0
    key = described_class.extract("GET", %w[v1 responses], body: -> { reads += 1; {} })
    expect(key).to be_nil
    expect(reads).to eq(0)
  end

  it "round-robins an unrecognized route without reading the body" do
    reads = 0
    key = described_class.extract("POST", %w[studio], body: -> { reads += 1; {} })
    expect(key).to be_nil
    expect(reads).to eq(0)
  end

  it "round-robins /channels/:id/sessions (minting — no existing session to be sticky about)" do
    key = described_class.extract("POST", %w[channels widget sessions], body: body_for({ "session_id" => "sess-6" }))
    expect(key).to be_nil
  end

  it "round-robins when the field is missing" do
    key = described_class.extract("POST", %w[v1 responses], body: body_for({ "agent" => "sales" }))
    expect(key).to be_nil
  end

  it "round-robins when the field is blank" do
    key = described_class.extract("POST", %w[v1 responses], body: body_for({ "user" => "" }))
    expect(key).to be_nil
  end

  it "round-robins on a malformed body instead of raising" do
    key = described_class.extract("POST", %w[v1 responses], body: -> { raise JSON::ParserError, "bad json" })
    expect(key).to be_nil
  end

  it "round-robins when the body is not a JSON object" do
    key = described_class.extract("POST", %w[v1 responses], body: -> { [1, 2, 3] })
    expect(key).to be_nil
  end
end
