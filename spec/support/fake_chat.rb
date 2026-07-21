# frozen_string_literal: true

# Double of the RubyLLM chat with the EXACT surface the Executor uses (stages 5-7).
# Records what it received and lets you drive the registered callbacks, simulating
# RubyLLM's sequential tool-use loop — without reimplementing any of it. Reused by
# task 12's integration.
class FakeChat
  ToolCall = Struct.new(:name, :arguments, :id)
  Response = Struct.new(:content)

  attr_reader :instructions, :tools, :messages, :asked
  # script: proc run in the chat's context during #ask (may call
  # emit_chunk/fire_tool_call/fire_tool_result). final_content: content of the final
  # response.
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

  # tool_calls/tool_call_id are optional (§11 R1 rehydration): recorded only when
  # present, so existing callers that seed plain {role, content} are unaffected.
  def add_message(role:, content:, tool_calls: nil, tool_call_id: nil)
    msg = { role: role, content: content }
    msg[:tool_calls] = tool_calls if tool_calls
    msg[:tool_call_id] = tool_call_id if tool_call_id
    @messages << msg
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

  # Drives the registered callbacks (simulates RubyLLM's loop). Propagates any
  # exception raised inside the callback (e.g. the max_tool_calls guard-rail).
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
      instance_exec(&@script) # script uses emit_chunk/fire_tool_call/fire_tool_result
    else
      emit_chunk("chunk")
    end
    Response.new(@final_content)
  end

  # Emits a streaming chunk (as RubyLLM does in the ask block).
  def emit_chunk(text)
    @on_chunk&.call(Response.new(text))
  end
end
