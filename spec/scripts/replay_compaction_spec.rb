# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "tmpdir"

# Integration proof of the real-replay compaction measurement. Builds a store in
# the production layout (real SessionStore + ContextTraceStore over a temp
# SQLite backend), shells out to the script, and asserts the C3 criterion is
# measured from the STORE, not from a synthetic transcript: a session whose
# history repeats a byte-identical big tool result reports a drop, a session
# with only short/different repeats reports none. HERMETIC: read-only on the
# temp store, no provider, no network.
RSpec.describe "scripts/replay_compaction.rb" do
  let(:script) { File.expand_path("../../scripts/replay_compaction.rb", __dir__) }

  def run(store_path)
    base = { "DEEPSEEK_API_KEY" => nil, "ADMIN_TOKEN" => nil }
    Open3.capture2e(base, "ruby", script, store_path, unsetenv_others: false)
  end

  it "reports the dedupe drop on a session that repeats a big tool result, and none on one that does not" do
    Dir.mktmpdir do |dir|
      backend = Insika::Stores::SQLite.new(path: File.join(dir, "replay.db"))
      sessions = Insika::SessionStore.new(store: backend)
      traces = Insika::ContextTraceStore.new(store: backend)

      big = "catalog page with many product rows " * 20 # ~640 chars, >= MIN_LENGTH
      short = "small output"
      repeat = ->(id) do
        sessions.append_messages(id, [{ "role" => "user", "content" => "show me the catalog" },
                                      { "role" => "assistant", "content" => "sure",
                                        "tool_calls" => [{ "id" => "c", "name" => "search" }] },
                                      { "role" => "tool", "content" => big, "tool_call_id" => "c" }])
      end

      sessions.create(id: "s1")
      repeat.call("s1")
      repeat.call("s1")
      sessions.append_messages("s1", [{ "role" => "user", "content" => "again?" }])

      sessions.create(id: "s2")
      sessions.append_messages("s2", [{ "role" => "user", "content" => "one" },
                                      { "role" => "assistant", "content" => "ok",
                                        "tool_calls" => [{ "id" => "c", "name" => "search" }] },
                                      { "role" => "tool", "content" => short, "tool_call_id" => "c" },
                                      { "role" => "user", "content" => "two" },
                                      { "role" => "assistant", "content" => "ok",
                                        "tool_calls" => [{ "id" => "c2", "name" => "search" }] },
                                      { "role" => "tool", "content" => short, "tool_call_id" => "c2" },
                                      { "role" => "user", "content" => "three" }])

      traces.record(session_id: "s1",
                    entry: { task_id: "t1", turn: 1, at: Time.now.utc.iso8601, cap: 8_000,
                             used: 500, evicted: [], categories: { "prompt" => { "tokens" => 500 } },
                             tools: { count: 1, tokens: 10 } })

      out, status = run(File.join(dir, "replay.db"))
      expect(status).to be_success, out
      expect(out).to include("sessions replayed: 2")
      expect(out).to match(/sessions where it changed any turn: 1\/2/)
      expect(out).to match(/^\s+s1\s+3\s+\d+\s+\d+\s+-\d+\.\d+%/) # the repeat drops tokens
      expect(out).to match(/^\s+s2\s+3\s+\d+\s+\d+\s+\+0\.0%/) # short repeats stay untouched
      expect(out).to include("budget pressure at each session's own recorded cap")
      expect(out).to match(/exceeds the cap: 0\/1 \(off\) -> 0\/1 \(on\)/)
    end
  end

  it "--help prints the methodology header without touching a store" do
    out, status = Open3.capture2e("ruby", script, "--help")
    expect(status).to be_success
    expect(out).to match(/Real-replay measurement of the C3 criterion/)
    expect(out).to include("Read-only")
  end
end
