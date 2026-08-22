# frozen_string_literal: true

# ---
# title: Research Analyst
# trail: Advanced
# description: Insika.system fan-out — three specialist subagents research different angles of a topic in parallel, the lead delegates and synthesizes.
# capabilities: subagents, delegation, system
# ---
#
# research-analyst — a lead agent with no expertise of its own: it must
# delegate. spawn_subagents fans out to three specialists on separate angles
# of a business idea, IN PARALLEL (each in its own isolated context), then
# the lead synthesizes one recommendation.
#
#   DEEPSEEK_API_KEY=sk-... ruby research-analyst/agent.rb "a subscription box for specialty coffee"
#   DEEPSEEK_API_KEY=sk-... ruby research-analyst/agent.rb --serve
require "insika"

team = Insika.system do
  provider :deepseek

  agent("market") do
    model "deepseek-v4-flash"
    instructions "Research the MARKET angle of a business idea: audience, demand, competitors. Three sentences."
  end
  agent("technical") do
    model "deepseek-v4-flash"
    instructions "Research the TECHNICAL/OPERATIONAL angle of a business idea: what it takes to build and run it. Three sentences."
  end
  agent("risk") do
    model "deepseek-v4-flash"
    instructions "Research the RISK angle of a business idea: what could make it fail. Three sentences."
  end

  agent "analyst" do
    model "deepseek-v4-flash"
    instructions <<~PROMPT
      You are a research LEAD with no expertise of your own — never answer
      from your own knowledge. Given a business idea, call spawn_subagents
      once with all three specialists (market, technical, risk), then
      synthesize their findings into one short recommendation: go, no-go, or
      go-with-changes, and why.
    PROMPT
    subagents "market", "technical", "risk"
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.delete("--serve")
    team.serve
  else
    topic = ARGV.join(" ")
    topic = "a subscription box for specialty coffee" if topic.empty?
    puts team.reply("analyst", "Research this idea: #{topic}")
  end
end

team
