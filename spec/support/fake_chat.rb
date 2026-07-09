# frozen_string_literal: true

# Duplo do chat do RubyLLM com a superfície EXATA usada pelo Executor
# (estágios 5-7). Grava o que recebeu e permite dirigir os callbacks
# registrados, simulando o loop de tool-use sequencial do RubyLLM — sem
# reimplementar nada dele. Reusado pela integração da task 12.
class FakeChat
  ToolCall = Struct.new(:name, :arguments, :id)
  Response = Struct.new(:content)

  attr_reader :instructions, :tools, :messages, :asked

  def initialize
    @tools = []
    @messages = []
    @before_tool_call = nil
    @after_tool_result = nil
    @asked = nil
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

  def ask(message)
    @asked = message
    yield Response.new("chunk") if block_given?
    Response.new("final")
  end
end
