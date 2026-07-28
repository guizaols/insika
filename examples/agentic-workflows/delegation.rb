# frozen_string_literal: true

# ORCHESTRATOR-WORKERS — the MODEL decides who to delegate to, and when.
#
#   run: DEEPSEEK_API_KEY=sk-... ruby examples/agentic-workflows/delegation.rb
#
# The other examples in this folder put the decision in Ruby. Here the parent gets
# two system tools and chooses for itself:
#
#   spawn_subagent  — one child, blocking, returns its answer
#   spawn_subagents — N children IN PARALLEL, one combined result
#
# Each child runs in an ISOLATED context: it does not see the parent's
# conversation, so the parent must pass everything the child needs. Capability
# never inherits — a child's tools, skills and own subagents come from its own
# profile. Environment (model, thinking) inherits as a default.

require "insika"

CODE = <<~RUBY
  def find_user(name)
    User.where("name = '\#{name}'").to_a.select { |u| u.active }
  end
RUBY

desk = Insika.system do
  provider :deepseek

  agent("security")    { model "deepseek-chat"; instructions "Security reviewer. ONE sentence." }
  agent("performance") { model "deepseek-chat"; instructions "Performance reviewer. ONE sentence." }

  agent "lead" do
    model "deepseek-chat"
    # The parent is told it has no expertise of its own. Without that, a capable
    # model happily answers alone and the delegation never happens.
    instructions <<~P
      You are a review LEAD. You have no reviewing expertise yourself and must
      never review code from your own knowledge. Delegate:
        · a full review  → call spawn_subagents once, with both specialists
        · one aspect only → call spawn_subagent
      Then report each finding on its own line, labelled with the agent's name.
    P
    subagents "security", "performance"
  end
end

t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
answer = desk.reply("lead", "Do a full review of:\n#{CODE}")
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t

puts answer
puts
puts format("one parent turn, two children in parallel, %.1fs", elapsed)

# Ground truth, not vibes: every child turn is its own Task in the store.
tasks = desk.runtime.graph.task_store.each_id.map { |id| desk.runtime.graph.task_store.find(id) }
agents = tasks.map { |task| (task.command["payload"] || {})["agent"] }
puts "tasks by agent: #{agents.tally.inspect}"
puts
puts "Nothing forces the model to delegate — that is the trade. If it answers alone,"
puts "the tasks above show only the parent, and the prompt is what needs work."
