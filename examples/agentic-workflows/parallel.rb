# frozen_string_literal: true

# PARALLEL (fan-out / fan-in) — independent specialists at once, then synthesized.
#
#   run: DEEPSEEK_API_KEY=sk-... ruby examples/agentic-workflows/parallel.rb
#
# `ctx.gather` runs the blocks concurrently on the turn's reactor and returns the
# values IN ORDER. An LLM turn is almost all waiting on the provider, so the waits
# overlap: wall-clock is the SLOWEST branch, not the sum. The script proves it by
# running the same work sequentially afterwards.

require "insika"

CODE = <<~RUBY
  def find_user(name)
    User.where("name = '\#{name}'").to_a.select { |u| u.active }
  end
RUBY

review = Insika.system do
  provider :deepseek

  agent("security")    { model "deepseek-v4-flash"; instructions "Review code for SECURITY issues. ONE sentence." }
  agent("performance") { model "deepseek-v4-flash"; instructions "Review code for PERFORMANCE issues. ONE sentence." }
  agent("style")       { model "deepseek-v4-flash"; instructions "Review code for Ruby STYLE. ONE sentence." }

  agent "lead" do
    model "deepseek-v4-flash"
    instructions "Given several review notes, output the single highest-priority action. ONE sentence."
  end

  workflow "review_parallel",
           description: "Three reviewers at once, then one prioritized action.",
           input: { type: "object", properties: { code: { type: "string" } }, required: ["code"] } do |input, ctx|
    code = input["code"]

    # fan-out — three turns in flight, results in declaration order
    security, performance, style = ctx.gather(
      -> { ctx.ask("security",    code) },
      -> { ctx.ask("performance", code) },
      -> { ctx.ask("style",       code) }
    )

    # fan-in — one more turn synthesizes them
    action = ctx.ask("lead", "security: #{security}\nperformance: #{performance}\nstyle: #{style}")

    { "security" => security, "performance" => performance, "style" => style, "action" => action }
  end

  # The same three reviewers, one after another — the baseline to compare against.
  workflow "review_sequential",
           input: { type: "object", properties: { code: { type: "string" } }, required: ["code"] } do |input, ctx|
    code = input["code"]
    { "notes" => ["security", "performance", "style"].map { |a| ctx.ask(a, code) } }
  end
end

def timed
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  value = yield
  [value, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t]
end

result, parallel_s   = timed { review.run("review_parallel",   input: { "code" => CODE }) }
_baseline, serial_s  = timed { review.run("review_sequential", input: { "code" => CODE }) }

puts "security:    #{result['security']}"
puts "performance: #{result['performance']}"
puts "style:       #{result['style']}"
puts
puts "ACTION:      #{result['action']}"
puts
puts format("3 reviewers in parallel: %.1fs (+1 synthesis turn)", parallel_s)
puts format("the same 3, sequentially: %.1fs", serial_s)
puts "wall-clock is the slowest branch, not the sum."
