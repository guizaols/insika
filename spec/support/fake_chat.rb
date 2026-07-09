# frozen_string_literal: true

# Duplo do chat do RubyLLM com a superfície EXATA usada pelo Executor
# (estágios 5-7). Grava o que recebeu e permite dirigir os callbacks
# registrados, simulando o loop de tool-use sequencial do RubyLLM — sem
# reimplementar nada dele. Reusado pela integração da task 12.
class FakeChat
  ToolCall = Struct.new(:name, :arguments, :id)
  Response = Struct.new(:content)

  attr_reader :instructions, :tools, :messages, :asked
  # script: proc rodado no contexto do chat durante #ask (pode chamar
  # emit_chunk/fire_tool_call/fire_tool_result). final_content: conteúdo da
  # resposta final.
  attr_accessor :script, :final_content

  def initialize
    @tools = []
    @messages = []
    @before_tool_call = nil
    @after_tool_result = nil
    @asked = nil
    @script = nil
    @final_content = "final"
  end

  def with_instructions(text)
    @instructions = text
    self
  end

  def with_tools(*tools)
    @tools.concat(tools)
    self
  end

  def add_message(role:, content:)
    @messages << { role: role, content: content }
    self
  end

  def before_tool_call(&blk)
    @before_tool_call = blk
    self
  end

  def after_tool_result(&blk)
    @after_tool_result = blk
    self
  end

  # Dirige os callbacks registrados (simula o loop do RubyLLM). Propaga qualquer
  # exceção levantada dentro do callback (ex.: o guard-rail de max_tool_calls).
  def fire_tool_call(name:, arguments: {}, id: "call_1")
    @before_tool_call&.call(ToolCall.new(name, arguments, id))
  end

  def fire_tool_result(result)
    @after_tool_result&.call(result)
  end

  def ask(message, &on_chunk)
    @asked = message
    @on_chunk = on_chunk
    if @script
      instance_exec(&@script) # script usa emit_chunk/fire_tool_call/fire_tool_result
    else
      emit_chunk("chunk")
    end
    Response.new(@final_content)
  end

  # Emite um chunk de streaming (como o RubyLLM faz no bloco do ask).
  def emit_chunk(text)
    @on_chunk&.call(Response.new(text))
  end
end
