# frozen_string_literal: true

# Shim de RubyLLM carregado no processo do smoke via RUBYOPT=-I (o `require
# "ruby_llm"` lazy do Executor/LoadSkill resolve para cá em vez da gem real). É
# ANDAIME DE TESTE, não produção: espelha só a superfície que o Executor usa
# (create_chat/with_instructions/with_tools/add_message/before_tool_call/
# after_tool_result/ask com bloco de chunks) — nada do runtime de LLM é
# reimplementado. Comportamento roteirizado por ENV.
require "async"

module RubyLLM
  # config/wiring de produção chamaria isto; o smoke não, mas mantemos por
  # robustez (não faz nada útil aqui).
  def self.configure
    yield(Object.new) if block_given?
  end

  # -> chat fake. Assinatura idêntica à usada em Executor#create_chat.
  def self.chat(model:, provider: nil, assume_model_exists: false)
    FakeChat.new
  end

  # Base das tools (LoadSkill herda). Só as class-methods usadas na DEFINIÇÃO da
  # classe (description/param) — no smoke o perfil não tem skills, então
  # LoadSkill nem é instanciada.
  class Tool
    def self.description(_text = nil); end
    def self.param(_name, **_opts); end
  end

  # Chat roteirizado. Dois modos:
  #   trava   (default): emite 1 chunk, grava o marker SMOKE_TURN_STARTED e
  #                      BLOQUEIA (janela determinística p/ o kill -9).
  #   complete (SMOKE_MODE=complete): emite 1 chunk e retorna a resposta final.
  class FakeChat
    Response = Struct.new(:content)

    def with_instructions(_text) = self
    def with_tools(*_tools) = self
    def add_message(role:, content:) = self
    def before_tool_call(&blk) = (@before = blk) && self
    def after_tool_result(&blk) = (@after = blk) && self

    def ask(message, &on_chunk)
      on_chunk&.call(Response.new("processando... "))

      return Response.new("resposta final para: #{message}") if ENV["SMOKE_MODE"] == "complete"

      # modo "trava": sinaliza o início do turno e bloqueia para sempre.
      File.write(ENV.fetch("SMOKE_TURN_STARTED"), "started")
      loop { Async::Task.current.sleep(0.1) } # nunca retorna; o kill -9 mata o processo
    end
  end
end
