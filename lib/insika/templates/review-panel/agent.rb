# frozen_string_literal: true

# ---
# title: Review Panel
# trail: Teams
# description: Two specialists reviewed in parallel by a synthesizing lead, explicit target agent (Insika.system + subagents).
# capabilities: subagents, delegation, system
# ---
#
# review-panel — promotes the examples/README.md snippet to a runnable
# template: a "reviewer" lead that has no expertise of its own delegates to
# two specialists (security, performance) IN PARALLEL, then synthesizes.
#
#   DEEPSEEK_API_KEY=sk-... ruby review-panel/agent.rb
#   DEEPSEEK_API_KEY=sk-... ruby review-panel/agent.rb --serve
require "insika"

panel = Insika.system do
  provider :deepseek

  agent("security")    { model "deepseek-v4-flash"; instructions "Review code for SECURITY issues. Two sentences." }
  agent("performance") { model "deepseek-v4-flash"; instructions "Review code for PERFORMANCE issues. Two sentences." }

  agent "reviewer" do
    model "deepseek-v4-flash"
    instructions <<~PROMPT
      You are a review LEAD with no reviewing expertise of your own — never
      review from your own knowledge. Call spawn_subagents once with both
      specialists (security, performance), then synthesize their findings
      into the single highest-priority fix.
    PROMPT
    subagents "security", "performance"
  end
end

if __FILE__ == $PROGRAM_NAME
  code = <<~RUBY
    def find_user(name)
      User.where("name = '\#{name}'").to_a.select { |u| u.active }
    end
  RUBY

  if ARGV.delete("--serve")
    panel.serve
  else
    puts panel.reply("reviewer", "Review this code:\n#{code}")
  end
end

panel
