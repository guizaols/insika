# frozen_string_literal: true

require_relative "../lib/harness"

# RubyLLM real, se instalada; senão o stub requerível (doc 03 §7). Feito cedo p/
# que o `require "ruby_llm"` de tools/load_skill.rb (lazy em produção) resolva
# nos testes. O stub NUNCA sombreia a gem real: só entra no load path na falta.
begin
  require "ruby_llm"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("support/stubs", __dir__))
  require "ruby_llm"
end

# Andaimes de teste (ex.: fake chat). Não-recursivo: exclui support/stubs.
Dir[File.join(__dir__, "support", "*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
