# frozen_string_literal: true

# Carregado só se a gem não estiver presente. Define APENAS a superfície de
# classe que Harness::Tools::LoadSkill usa em load-time — nenhum comportamento
# de runtime é reimplementado (RubyLLM First não é violado: isto é andaime de
# teste para a suíte rodar sem a gem, doc 03 §7).
begin
  require "ruby_llm"
rescue LoadError
  module RubyLLM
    class Tool
      def self.description(_text = nil); end
      def self.param(_name, **_opts); end
    end
  end
end
