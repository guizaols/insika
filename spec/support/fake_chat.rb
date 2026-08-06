# frozen_string_literal: true

# Double of the RubyLLM chat with the EXACT surface the Executor uses (stages 5-7).
# Records what it received and lets you drive the registered callbacks, simulating
# RubyLLM's sequential tool-use loop — without reimplementing any of it. Reused by
# task 12's integration.
class FakeChat
  ToolCall = Struct.new(:name, :arguments, :id)
  Response = Struct.new(:content) # content-only chunk: does NOT respond to #thinking
  # A completed message, as the gem hands it to `after_message`. TurnOutput reads
  # exactly `role` + `tool_call?` off it: a message that called a tool was not the
  # answer. The real Chat fires this for the assistant message BEFORE running the
  # tools (complete_once -> after_message -> handle_tool_calls), which is why
  # #fire_tool_call closes the message first — see ruby_llm_contract_spec.
  Message = Struct.new(:role, :content, :tool_calls) do
    def tool_call? = !(tool_calls.nil? || tool_calls.empty?)
  end
  # Reasoning chunk, shaped like RubyLLM's: the text lives in chunk.thinking.text and
  # content is nil (the provider streams the deliberation BEFORE the answer).
  Thought = Struct.new(:text)
  ThinkingChunk = Struct.new(:content, :thinking)

  attr_reader :instructions, :tools, :messages, :asked
  # Item 30: whatever the LAST with_tools passed as `concurrency:` (nil = the
  # serial default). The real Chat exposes it as #concurrency; the contract spec
  # pins that the keyword exists there too.
  attr_reader :concurrency
  # script: proc run in the chat's context during #ask (may call
  # emit_chunk/fire_tool_call/fire_tool_result). final_content: content of the final
  # response. model: optional stub read by ChatBuilder's provider check (§11 R3);
  # nil by default (provider check -> false, caching stays off).
  attr_accessor :script, :final_content, :model

  def initialize
    @tools = []
    @messages = []
    @before_tool_call = nil
    @after_tool_result = nil
    @after_message = nil
    @streamed = +""
    @asked = nil
    @script = nil
    @final_content = "final"
  end

  def with_instructions(text)
    @instructions = text
    self
  end

  def with_tools(*tools, concurrency: nil)
    @tools.concat(tools)
    @concurrency = concurrency
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

  def after_message(&blk)
    @after_message = blk
    self
  end

  # Drives the registered callbacks (simulates RubyLLM's loop). Propagates any
  # exception raised inside the callback (e.g. the max_tool_calls guard-rail).
  #
  # Closes the assistant message first, WITH the call on it: in the gem the model
  # cannot ask for a tool and keep talking in the same message, so whatever was
  # streamed before this point is narration, not the answer. A double that skipped
  # the boundary would let intermediate text pass for the answer here and only here.
  def fire_tool_call(name:, arguments: {}, id: "call_1")
    call = ToolCall.new(name, arguments, id)
    fire_end_message(role: "assistant", tool_calls: { id => call })
    @before_tool_call&.call(call)
  end

  # Closes a message, as the gem's `after_message` does. Each message streams its
  # own text, so the "did this one stream anything?" tracker resets with it.
  def fire_end_message(role: "assistant", content: nil, tool_calls: nil)
    @streamed = +""
    @after_message&.call(Message.new(role, content, tool_calls))
  end

  def fire_tool_result(result)
    @after_tool_result&.call(result)
  end

  def ask(message, &on_chunk)
    @asked = message
    @on_chunk = on_chunk
    @streamed = +""
    if @script
      instance_exec(&@script) # script uses emit_chunk/fire_tool_call/fire_tool_result
    else
      emit_chunk(@final_content)
    end
    # A tool with `halt_when` ended the turn: the REAL Chat returns the Tool::Halt
    # from its loop instead of a Message (see ruby_llm_contract_spec), so the double
    # must be able to as well — otherwise the Executor's branch is untestable here and
    # only production would find out. A halt always came from a tool call, so the
    # assistant message that carried it is closed here for the scripts that halt
    # without going through #fire_tool_call.
    if @halt_with
      fire_end_message(role: "assistant", tool_calls: { "call_halt" => "halt" })
      return RubyLLM::Tool::Halt.new(@halt_with)
    end

    # A real provider's message content IS what it streamed — the gem builds the
    # Message out of the chunks. A script that only set `final_content` (or that
    # streamed its text before a tool call) would otherwise close a message whose
    # text no chunk carried, and TurnOutput publishes what was streamed.
    emit_chunk(@final_content) if @streamed.empty? && !@final_content.to_s.empty?
    fire_end_message(role: "assistant", content: @final_content)
    Response.new(@final_content)
  end

  # Makes the next #ask return a Tool::Halt carrying this payload.
  def halt_with!(payload) = (@halt_with = payload)

  # Emits a streaming chunk (as RubyLLM does in the ask block).
  def emit_chunk(text)
    @streamed << text.to_s
    @on_chunk&.call(Response.new(text))
  end

  # Emits a REASONING chunk (DeepSeek reasoning_content / Anthropic thinking block).
  def emit_thinking(text)
    @on_chunk&.call(ThinkingChunk.new(nil, Thought.new(text)))
  end
end
