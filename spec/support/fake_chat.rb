# frozen_string_literal: true

# Double of the RubyLLM chat with the EXACT surface the Executor uses (stages 5-7).
# Records what it received and lets you drive the registered callbacks, simulating
# RubyLLM's sequential tool-use loop — without reimplementing any of it. Reused by
#'s integration.
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
  attr_reader :concurrency, :temperature, :max_output_tokens, :provider_options, :thinking
  # how many times #complete was driven (the steer overflow round).
  attr_reader :completes
  # script: proc run in the chat's context during #ask (may call
  # emit_chunk/fire_tool_call/fire_tool_result). final_content: content of the final
  # response. model: optional stub read by ChatBuilder's provider check (R3);
  # nil by default (provider check -> false, caching stays off).
  attr_accessor :script, :final_content, :model

  def initialize
    @tools = []
    @messages = []
    @before_tool_call = []
    @after_tool_result = []
    # ADDITIVE, like the gem's: `@callbacks[name] << block`. A single slot here made the
    # double silently drop every registration but the last — and stage 6 registers two
    # (TurnOutput's publishing boundary and the steer injector), so the one
    # that lost would have looked like a feature that never fires.
    @after_message = []
    @streamed = +""
    @asked = nil
    @script = nil
    @final_content = "final"
    @completes = 0
    @complete = false
    @provider_options = {}
  end

  def with_instructions(text, append: false, cache_until_here: false)
    @instructions = append ? [@instructions, text].compact.join("\n") : text
    self
  end

  def with_tools(*tools)
    @tools.concat(tools)
    self
  end

  def with_tool_options(concurrency: nil, **)
    @concurrency = concurrency
    self
  end

  def with_temperature(value) = (@temperature = value; self)
  def with_max_output_tokens(value) = (@max_output_tokens = value; self)
  def with_provider_options(value) = (@provider_options.merge!(value); self)
  def with_thinking(enabled = true, **options) = (@thinking = enabled ? options : false; self)

  # tool_calls/tool_call_id are optional (R1 rehydration): recorded only when
  # present, so existing callers that seed plain {role, content} are unaffected.
  def add_message(role:, content:, tool_calls: nil, tool_call_id: nil)
    msg = { role: role, content: content }
    msg[:tool_calls] = tool_calls if tool_calls
    msg[:tool_call_id] = tool_call_id if tool_call_id
    @messages << msg
    @complete = false if role.to_s == "user"
    self
  end

  def before_tool_call(&blk)
    @before_tool_call << blk
    self
  end

  def after_tool_result(&blk)
    @after_tool_result << blk
    self
  end

  def after_message(&blk)
    @after_message << blk
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
    @before_tool_call.each { |blk| blk.call(call) }
  end

  # Closes a message, as the gem's `after_message` does. Each message streams its
  # own text, so the "did this one stream anything?" tracker resets with it.
  def fire_end_message(role: "assistant", content: nil, tool_calls: nil)
    @streamed = +""
    @complete = true if role.to_s == "assistant" && (tool_calls.nil? || tool_calls.empty?)
    @after_message.each { |blk| blk.call(Message.new(role, content, tool_calls)) }
  end

  # Only the RAW-result callback (the gem's `after_tool_result`), which is where a
  # `ToolDefinition::Halt` is still recognizable. The `role: tool` message that follows it in the
  # gem is #fire_tool_result_message — a script that needs the batch boundary calls both,
  # in that order.
  def fire_tool_result(result)
    @after_tool_result.each { |blk| blk.call(result) }
  end

  # The gem's `add_tool_result_message`: the result becomes a `role: tool` message AND
  # closes it through `after_message`. That boundary — the LAST result of a batch — is
  # where appends a steered message, so a double that only fired
  # `after_tool_result` could not exercise it at all.
  def fire_tool_result_message(result, id: "call_1")
    add_message(role: :tool, content: result.to_s, tool_call_id: id)
    fire_end_message(role: "tool", content: result.to_s)
  end

  def ask(message, with: nil, &on_chunk)
    @asked = message
    @attachments = with
    round(&on_chunk)
  end

  def ask_later(message, with: nil)
    @asked = message
    @attachments = with
    @pending_ask = true
    @complete = false
    self
  end

  def step(&on_chunk)
    @complete = true
    if @pending_ask
      @pending_ask = false
      @attachments ? ask(@asked, with: @attachments, &on_chunk) : ask(@asked, &on_chunk)
    else
      complete(&on_chunk)
    end
  end

  def complete? = @complete
  def awaiting_approval? = false

  # The gem's `Chat#complete`: another model step on the history AS IT IS, with no
  # new user message. The steer overflow round goes through here — `ask(nil)` would
  # append an empty user message after the injected ones, which providers refuse.
  def complete(&on_chunk)
    @completes += 1
    round(&on_chunk)
  end

  private def round(&on_chunk)
    @on_chunk = on_chunk
    @streamed = +""
    if @script
      instance_exec(&@script) # script uses emit_chunk/fire_tool_call/fire_tool_result
    else
      emit_chunk(@final_content)
    end
    # The executor captures this raw tool result and stops driving Chat#step.
    if @halt_with
      fire_end_message(role: "assistant", tool_calls: { "call_halt" => "halt" })
      halt = Insika::ToolDefinition::Halt.new(@halt_with)
      fire_tool_result(halt)
      return halt
    end

    # A real provider's message content IS what it streamed — the gem builds the
    # Message out of the chunks. A script that only set `final_content` (or that
    # streamed its text before a tool call) would otherwise close a message whose
    # text no chunk carried, and TurnOutput publishes what was streamed.
    emit_chunk(@final_content) if @streamed.empty? && !@final_content.to_s.empty?
    fire_end_message(role: "assistant", content: @final_content)
    Response.new(@final_content)
  end

  # Makes the next round emit Insika's halt marker carrying this payload.
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
