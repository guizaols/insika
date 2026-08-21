# frozen_string_literal: true

# ---
# title: Daily Digest
# trail: Always-on
# description: A recurring schedule (RFC-0037) plus save_artifact (RFC-0038) build and publish a self-contained HTML report — no store, fake in-memory numbers only.
# capabilities: schedule, save_artifact, skill
# ---
#
# daily-digest — the report pipeline in one file: a recurring schedule (the
# engine's own tick fires it), a daily-digest skill (the inline-SVG
# pattern), the save_artifact tool (the report destination) and the
# per-agent allowlist that gates it. No store content — fake, in-memory
# "sales" numbers only.
#
#   DEEPSEEK_API_KEY=sk-... ruby daily-digest/agent.rb
#   DEEPSEEK_API_KEY=sk-... ruby daily-digest/agent.rb --serve
#       # --serve: open /studio, log in with the printed token, then send a
#       # message to the "reporter" agent in the Playground — the artifact
#       # lands on the Artifacts tab. The schedule fires the same run at
#       # 22:00 America/Sao_Paulo on its own.
require "insika"

todays_sales = "Coffee 128 units ($512), Tea 64 units ($192), Pastries 40 units ($160)."

reporter = Insika.agent("reporter") do
  model "deepseek-v4-flash"
  provider :deepseek

  instructions <<~PROMPT
    You produce the daily sales digest from the numbers given to you in the
    message. Follow the daily-digest skill exactly, then save the finished
    page with save_artifact (HTML with inline SVG). End your reply with the
    artifact url, on its own line, prefixed with "Report: ".
  PROMPT

  # The per-agent allowlist IS the switch for save_artifact — without this
  # line the model never even sees the tool.
  tools %w[save_artifact]

  # A recurring turn — the engine's tick fires it (RFC-0037). session_mode:
  # "new" = a fresh session per run (the report shape); the overrides raise
  # the chat-time ceilings a real report needs.
  schedule "daily_report", cron: "0 22 * * *", tz: "America/Sao_Paulo",
           message: "Run the daily report now. Today's sales: #{todays_sales}",
           session_mode: "new",
           overrides: { turn_timeout: 600, max_tool_calls: 120 }

  # The generic, store-free skill: how a report is BUILT — the inline-SVG
  # pattern (palette, table, pure-SVG bars, light/dark). No store ids, no
  # queries — that half belongs in a merchant's pack, not here.
  skill "daily-digest",
        description: "How to build the daily sales digest as a self-contained HTML report",
        instructions: <<~MD
          Build the digest as ONE self-contained HTML page:
          - a <style> block with a light palette (e.g. #f8fafc bg, #0f172a text,
            #6366f1 accent), plus a prefers-color-scheme: dark override;
          - one <table> of the numbers (th/tbody, right-aligned amounts);
          - one inline SVG bar chart (no <script>, no <img>, no <iframe>,
            no external fonts or fetches — the report is served with
            default-src 'none', so nothing external can load);
          - a title and the run date.
          Keep it readable on a phone. The report is the deliverable; the
          channel message is just the link to it.
        MD
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.delete("--serve")
    reporter.serve
  else
    puts reporter.reply("Run the daily report now. Today's sales: #{todays_sales}")
    puts "\nThen open the returned /studio/artifacts/<id> page (or --serve and look at the Artifacts tab)."
  end
end

reporter
