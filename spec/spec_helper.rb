# frozen_string_literal: true

require_relative "../lib/harness"

# Andaimes de teste (ex.: shim do RubyLLM p/ rodar sem a gem, fake chat).
Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
