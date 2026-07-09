# frozen_string_literal: true

# Stub requerível de RubyLLM para a suíte rodar SEM a gem (doc 03 §7). Só a
# superfície de classe que Harness::Tools::LoadSkill usa em load-time — nenhum
# comportamento de runtime é reimplementado (RubyLLM First não é violado: isto
# é andaime de teste). Fica em spec/support/stubs, que o spec_helper só põe no
# $LOAD_PATH quando a gem real está ausente.
module RubyLLM
  class Tool
    def self.description(_text = nil); end
    def self.param(_name, **_opts); end
  end
end
