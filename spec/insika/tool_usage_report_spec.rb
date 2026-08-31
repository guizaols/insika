# frozen_string_literal: true

require "spec_helper"

# the tool audit: tasks → sessions → tool_traces, judged against the
# agent's allowlist. Read-only; built over the REAL stores (memory backend) so the
# attribution path it exercises is the one the CLI runs.
RSpec.describe Insika::ToolUsageReport do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:trace_store) { Insika::ToolTraceStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:now) { Time.utc(2026, 8, 30, 12, 0, 0) }

  subject(:report) do
    described_class.new(task_store: task_store, tool_trace_store: trace_store,
                        profile_source: profiles, now: now).generate
  end

  def store_agent(id, tools_allow: nil)
    record = { "id" => id, "policies" => ["tool_allowlist"] }
    record["tools_allow"] = tools_allow unless tools_allow.nil?
    config_store.put("agents", id, record)
  end

  def turn(agent, session, at:)
    task_store.create(command: { type: :send_message, payload: { agent: agent } },
                      session_id: session, at: at.iso8601)
  end

  def trace(session, tool, at:, ok: true)
    trace_store.record(session_id: session,
                       entry: { turn: 1, tool: tool, call_id: "c",
                                args: {}, result: ok ? { "status" => "ok" } : { "error" => "boom" },
                                ms: 5, at: at.iso8601 })
  end

  it "flags an allowlisted tool never seen in any stored trace" do
    store_agent("bia", tools_allow: %w[search_products search_orders])
    turn("bia", "s1", at: now - 3600)
    trace("s1", "search_products", at: now - 3600)

    rows = report.rows.select { |r| r.kind == "never_called" }
    expect(rows.map(&:tool)).to eq(["search_orders"])
    expect(rows.first.agent).to eq("bia")
  end

  it "declares nothing never-called when the agent has no allowlist at all" do
    store_agent("bia")
    turn("bia", "s1", at: now - 3600)
    trace("s1", "anything", at: now - 3600)
    expect(report.rows.map(&:kind)).not_to include("never_called")
  end

  it "flags a tool whose in-window error rate crosses 30%" do
    store_agent("bia", tools_allow: %w[calc])
    turn("bia", "s1", at: now - 3600)
    trace("s1", "calc", at: now - 3600, ok: false)
    trace("s1", "calc", at: now - 3500, ok: false)
    trace("s1", "calc", at: now - 3400)

    row = report.rows.find { |r| r.kind == "error_rate" }
    expect([row.tool, row.detail]).to eq(["calc", "2/3 call(s) errored in the last 14 day(s) (67%)"])
  end

  it "does not flag a tool at or under the 30% threshold" do
    store_agent("bia", tools_allow: %w[calc])
    turn("bia", "s1", at: now - 3600)
    trace("s1", "calc", at: now - 3600, ok: false)
    trace("s1", "calc", at: now - 3500)
    trace("s1", "calc", at: now - 3400)
    trace("s1", "calc", at: now - 3300)
    expect(report.rows.map(&:kind)).not_to include("error_rate")
  end

  it "flags a tool last called before the window as stale, with the timestamp" do
    store_agent("bia", tools_allow: %w[old_tool])
    turn("bia", "s1", at: now - (20 * 86_400))
    trace("s1", "old_tool", at: now - (20 * 86_400))

    row = report.rows.find { |r| r.kind == "stale" }
    expect(row.tool).to eq("old_tool")
    expect(row.detail).to include((now - (20 * 86_400)).iso8601)
    # a stale tool is not ALSO an error-rate row: zero in-window calls
    expect(report.rows.map(&:kind)).to eq(["stale"])
  end

  it "attributes traces to the right agent via the task record" do
    store_agent("bia", tools_allow: %w[a])
    store_agent("duda", tools_allow: %w[a])
    turn("bia", "s1", at: now - 3600)
    trace("s1", "a", at: now - 3600)

    never = report.rows.select { |r| r.kind == "never_called" }
    expect(never.map(&:agent)).to eq(["duda"]) # bia called it; duda never did
  end

  it "narrows to one agent and lists it even with nothing flagged" do
    store_agent("bia", tools_allow: %w[a])
    store_agent("duda", tools_allow: %w[b])
    turn("bia", "s1", at: now - 3600)
    trace("s1", "a", at: now - 3600)

    narrowed = described_class.new(task_store: task_store, tool_trace_store: trace_store,
                                   profile_source: profiles, now: now).generate(agent: "bia")
    expect(narrowed.agents).to eq(["bia"])
    expect(narrowed.rows).to be_empty
    expect(narrowed.to_s).to include("bia: nothing flagged")
  end

  it "renders the human report grouped by agent" do
    store_agent("bia", tools_allow: %w[search_orders])
    expect(report.to_s).to include("tool usage — last 14 day(s)",
                                   "bia: 1 finding(s)",
                                   "never_called  search_orders")
  end

  it "round-trips to_h with string keys (the --json surface)" do
    store_agent("bia", tools_allow: %w[x])
    h = report.to_h
    expect(h["days"]).to eq(14)
    expect(h["rows"].first).to include("agent" => "bia", "tool" => "x", "kind" => "never_called")
  end
end
