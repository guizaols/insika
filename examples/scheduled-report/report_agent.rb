# frozen_string_literal: true

# scheduled-report — the report pipeline in one file: a recurring schedule
# (the engine's own tick fires it), a daily-digest skill (the inline-SVG
# pattern), the save_artifact tool (the report destination) and the per-agent
# allowlist that gates it. No store content — fake, in-memory "sales" only.
#
#   DEEPSEEK_API_KEY=sk-... ruby examples/scheduled-report/report_agent.rb
#   DEEPSEEK_API_KEY=sk-... ruby examples/scheduled-report/report_agent.rb --serve
#       # --serve: run the server; open /studio, log in with the printed token,
#       # then send a message to the "reporter" agent in the Playground —
#       # the artifact lands on the Artifacts tab.
require_relative "../../lib/insika"

reporter = Insika.agent("reporter") do
  model "deepseek-v4-flash"
  provider :deepseek

  instructions <<~PROMPT
    You produce the daily sales digest. Follow the daily-digest skill exactly,
    then save the finished page with save_artifact (HTML with inline SVG). End
    your reply with the artifact url, on its own line, prefixed with "Report: ".
  PROMPT

  # The per-agent allowlist IS the switch for save_artifact: without this line
  # the model never even sees the tool.
  tools %w[save_artifact]

  # A recurring turn — the engine's tick fires it (half of this
  # example). `session_mode: "new"` = a fresh session per run (the report
  # shape); the overrides raise the chat-time ceilings a real report needs.
  schedule "daily_report", cron: "0 22 * * *", tz: "America/Sao_Paulo",
           message: "Run the daily report now.",
           session_mode: "new",
           overrides: { turn_timeout: 600, max_tool_calls: 120 }

  # The generic, store-free skill: how a report is BUILT — the inline-SVG
  # pattern (palette, table, native controls, light/dark). No store ids, no
  # queries — that half is yours, and it lives in the merchant's pack, not here.
  skill "daily-digest",
        description: "How to build the daily sales digest as a self-contained HTML report",
        instructions: <<~MD
          Build ONE self-contained executive HTML report with a <style> block:
          - Lead with a clear title, period, generation date and concise,
            evidence-backed takeaway. Name sources and limitations. Use only
            supplied numbers; show missing data honestly and label demo data.
          - Use warm neutrals and one amber accent (or the merchant's accent),
            consistent type, spacing and KPI cards, and system dark mode.
          - Include a responsive inline SVG or HTML bar chart with clear labels,
            units and exact values, plus a captioned table with column headers.
          - Offer Chart/Table through labeled, focusable native radios grouped
            in a fieldset with a legend; use CSS :checked, not ARIA tabs.
          - Use hover/focus tooltips in reserved space; keep them visible when
            hovered. Add CSS highlights, a visible 2px focus outline, and
            details/summary for supporting evidence. Exact values
            must remain available on touch without hovering.
          - Use 140ms color/opacity transitions; disable them for reduced motion.
            No decorative animation. Print the full table and supporting details
            regardless of the selected view or collapsed state; hide controls.
          - This is a dated data snapshot, not a live feed. No scripts, event
            handlers, forms, iframe, external fonts or fetches. The report's
            default-src 'none' policy blocks external resources.
          Keep it readable on a phone. The channel message is just the link.
        MD
end

if ARGV.include?("--serve")
  # Serve /studio (Artifacts tab) + /v1 on :9292. The tick fires the schedule
  # on its own; you can also kick one run right now in the Playground.
  reporter.serve
else
  # One run now (what the schedule would fire at 22:00): the agent builds the
  # digest, saves it as an artifact and hands back the url.
  puts reporter.reply("Run the daily report now.")
  puts "\nThen open the returned /studio/artifacts/<id> page (or --serve and look at the Artifacts tab)."
end
