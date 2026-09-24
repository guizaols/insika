# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../lib/insika/studio/app"

RSpec.describe "Studio report navigation" do
  let(:profile) { Insika::AgentProfile.build(id: "reporter", model: "m") }
  let(:profiles) { double(all: [profile], ids: [profile.id], fetch: profile) }
  let(:goldens) { Insika::GoldenStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:app) do
    Class.new(Studio::App).configure(
      command_bus: double, profile_source: profiles, golden_store: goldens,
      event_stream: nil, config: { admin_token: "secret" }, session_secret: "x" * 64
    )
  end

  def get_page(path)
    mock = Rack::MockRequest.new(app)
    login = mock.get("/login")
    cookie = Array(login["set-cookie"]).map { |c| c.split(";").first }.join("; ")
    csrf = login.body[/name="_csrf" value="([^"]+)"/, 1]
    signed_in = mock.post("/login", "HTTP_COOKIE" => cookie,
                         params: { "token" => "secret", "_csrf" => csrf })
    cookie = Array(signed_in["set-cookie"]).map { |c| c.split(";").first }.join("; ")
    result = mock.get(path, "HTTP_COOKIE" => cookie)
    expect(result.status).to eq(200)
    result.body
  end

  it "submits the selected agent and period together, including custom periods" do
    body = get_page("/funnel?agent=reporter&period=14")
    form = body[%r{<form method="get" action="/studio/funnel".*?</form>}m]
    expect(form).to include('name="agent"', 'value="reporter" selected', 'name="period"', 'value="14" selected')
    expect(form).to include('type="submit"')
  end

  it "keeps the agent filter when selecting or starting an eval case and guards unsaved edits" do
    goldens.write({ "id" => "report-test", "agent" => "reporter", "turns" => [{ "user" => "Hello" }],
                  "expect" => { "rubric" => "Reply to the greeting" } })
    body = get_page("/evals?agent=reporter&id=report-test")
    expect(body).to include('href="/studio/evals?id=report-test&amp;agent=reporter"')
    expect(body).to include('href="/studio/evals?agent=reporter">New case</a>')
    expect(body).to match(%r{<form id="set-golden"[^>]*data-controller="dirty-guard"})
    expect(body).to include('aria-current="page"', 'data-list-filter-target="item"', 'name="_csrf"')
  end
end
