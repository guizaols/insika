# frozen_string_literal: true

require_relative "../lib/insika"

# Real RubyLLM if installed; otherwise the requireable stub (doc 03 §7). Done early
# so tools/load_skill.rb's `require "ruby_llm"` (lazy in production) resolves in the
# tests. The stub NEVER shadows the real gem: it only joins the load path when absent.
begin
  require "ruby_llm"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("support/stubs", __dir__))
  require "ruby_llm"
end

# Test scaffolding (e.g. fake chat). Non-recursive: excludes support/stubs.
Dir[File.join(__dir__, "support", "*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
