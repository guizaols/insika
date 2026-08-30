# frozen_string_literal: true

require "spec_helper"
require "open3"

# Guards the public session load benchmark. HERMETIC by construction: only the
# --help / --dry-run / validation paths run here, so no server, no provider key
# and no network are needed — a traffic run stays an operator action.
RSpec.describe "scripts/loadtest_session.rb" do
  let(:script) { File.expand_path("../../scripts/loadtest_session.rb", __dir__) }

  def run(*args)
    Open3.capture2e("ruby", script, *args)
  end

  it "--help prints the usage header without running" do
    out, status = run("--help")
    expect(status).to be_success
    expect(out).to match(/CONCURRENT SESSIONS/)
    expect(out).to include("--mode")
  end

  it "--dry-run prints the plan and the 7-step flow without sending traffic" do
    out, status = run("--mode", "both", "--levels", "1,10", "--dry-run")
    expect(status).to be_success
    expect(out).to include("agent=demo")
    expect(out).to include("http://localhost:9292")
    expect(out).to include("levels=1,10")
    expect(out).to include("sessions/mode=11")
    expect(out).to include("turns/mode=77")
    %w[greeting cep_invalid cep_valid search_corporal search_maos search_perfume faq_pagamento]
      .each { |step| expect(out).to include(step) }
    expect(out).to include("insika:demo")
  end

  it "rejects an unknown mode" do
    out, status = run("--mode", "nope")
    expect(status).not_to be_success
    expect(out).to match(/--mode must be stream\|steer\|both/)
  end

  it "rejects a malformed levels list" do
    out, status = run("--levels", "10,zero")
    expect(status).not_to be_success
    expect(out).to match(/--levels must be positive integers/)
  end

  it "--surface web requires --widget-id" do
    out, status = run("--surface", "web", "--dry-run")
    expect(status).not_to be_success
    expect(out).to match(/--surface web needs --widget-id/)
  end

  it "--surface web --dry-run plans the widget API requests" do
    out, status = run("--surface", "web", "--widget-id", "w-123", "--mode", "stream",
                      "--levels", "1", "--dry-run")
    expect(status).to be_success
    expect(out).to include("surface=web")
    expect(out).to include("widget=w-123")
    expect(out).to include("/api/widget/sessions")
    expect(out).to include("http://localhost:3000")
  end

  it "rejects an unknown surface" do
    out, status = run("--surface", "nope")
    expect(status).not_to be_success
    expect(out).to match(/--surface must be engine\|web/)
  end
end
