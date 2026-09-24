# frozen_string_literal: true

require "spec_helper"

# The real chat lifecycle runs here; only the provider network boundary is stubbed.
RSpec.describe "RubyLLM boundary contract" do
  before do
    raise "real ruby_llm 2 gem is required for the boundary contract" unless defined?(RubyLLM::Chat)
    expect(Gem.loaded_specs.fetch("ruby_llm").version.segments.first).to eq(2)
  end
  let(:context) { RubyLLM.context { |config| config.deepseek_api_key = "spec-only" } }
  let(:chat) { context.chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true) }
  let(:state) do
    Insika::TurnState.new(task: nil, profile: Insika::AgentProfile.build(id: "a", model: "m"),
                          turn: 1, message: "hello")
  end
  let(:builder) do
    Insika::ChatBuilder.new(tool_registry: Object.new, skill_catalog: Object.new,
                            checkpoint_store: Object.new, event_stream: Object.new, hooks: Insika::Hooks.new)
  end
  let(:executor) do
    Insika::Executor.new(context_builder: Object.new, policy_engine: Object.new, middleware: Object.new,
                         hooks: Insika::Hooks.new, tool_registry: Object.new, skill_catalog: Object.new,
                         profiles: {}, session_store: Object.new, task_store: Object.new,
                         checkpoint_store: Object.new, event_stream: Object.new)
  end

  def tool(name, &implementation)
    Class.new(RubyLLM::Tool) do
      define_method(:name) { name }
      define_method(:execute) { |tool_call: nil, **arguments| implementation.call(tool_call, arguments) }
    end.new
  end

  def call(id, name: "search", arguments: {})
    RubyLLM::ToolCall.new(id: id, name: name, arguments: arguments)
  end

  def tool_message(*calls)
    RubyLLM::Message.new(role: :assistant, content: "Looking", tool_calls: calls.to_h { |item| [item.id, item] })
  end

  it "exposes every chat method used by Insika" do
    methods = %i[with_instructions with_tools with_tool_options add_message before_tool_call after_tool_result
                 after_message ask_later step complete? awaiting_approval? messages model provider
                 with_temperature with_max_output_tokens with_provider_options with_thinking]
    expect(methods - RubyLLM::Chat.public_instance_methods).to be_empty
  end

  it "stages input, runs callbacks in order, and completes without adding another user message" do
    requested = call("c1", arguments: { "query" => "hello" })
    final = RubyLLM::Message.new(role: :assistant, content: "Found")
    events = []
    chat.with_tools(tool("search") { |received, args| events << [:execute, received.id, args]; "result" })
    chat.after_message { |message| events << [:first, message.role] }
    chat.after_message { |message| events << [:second, message.role] }
    chat.before_tool_call { |item| events << [:before, item.id] }
    chat.after_tool_result { |result| events << [:result, result] }
    expect(chat.provider).to receive(:complete).ordered.and_return(tool_message(requested))
    expect(chat.provider).to receive(:complete).ordered do |messages, **|
      expect(messages.map(&:role)).to eq(%i[user assistant tool])
      final
    end

    chat.ask_later("hello")
    expect(chat.messages.map(&:role)).to eq([:user])
    expect(chat.complete?).to be(false)
    expect(chat.step.tool_call?).to be(true)
    expect(events).to eq([[:first, :assistant], [:second, :assistant]])
    chat.step
    expect(events.last(5)).to eq([[:before, "c1"], [:execute, "c1", { query: "hello" }],
                                [:result, "result"], [:first, :tool], [:second, :tool]])
    expect(chat.step).to equal(final)
    expect(chat.complete?).to be(true)
    expect(chat.step).to be_nil
    expect(chat.messages.map { |message| [message.role, message.content, message.tool_call_id] }).to eq(
      [[:user, "hello", nil], [:assistant, "Looking", nil], [:tool, "result", "c1"], [:assistant, "Found", nil]]
    )
  end

  it "exposes raw Insika halts before serializing results and finishes the current batch" do
    halt = Insika::ToolDefinition::Halt.new("Delivered")
    ran = []
    events = []
    chat.with_tools(tool("stop") { ran << :stop; halt }, tool("other") { ran << :other; "ok" })
    builder.wire_callbacks(chat, state, ->(type, data) { events << [type, data] })
    state.chat = chat
    state.chat_baseline = 0
    expect(chat.provider).to receive(:complete).once.and_return(tool_message(call("c1", name: "stop"), call("c2", name: "other")))
    chat.ask_later("hello")

    expect(executor.send(:complete_chat, state, chat)).to equal(halt)
    expect(state.tool_halt).to equal(halt)
    expect(ran).to eq(%i[stop other])
    expect(chat.messages.last(2).map(&:content)).to eq(["Delivered", "ok"])
    expect(chat.complete?).to be(false) # Insika stops on the captured halt before another step.
    expect(events.select { |type, _| type == :tool_result }.map { |_, data| data[:call_id] }).to eq(%w[c1 c2])
    store = Insika::SessionStore.new(store: Insika::Stores::Memory.new)
    session = store.create
    store.append_messages(session.id, executor.send(:recorded_turn_messages, state))
    persisted = store.find(session.id).messages.map { |message| message.except("at") }
    expect(persisted).to eq([
      { "role" => "user", "content" => "hello" },
      { "role" => "assistant", "content" => "Looking", "tool_calls" => [
        { "id" => "c1", "name" => "stop", "arguments" => {} }, { "id" => "c2", "name" => "other", "arguments" => {} }
      ] },
      { "role" => "tool", "tool_call_id" => "c1", "content" => "Delivered" },
      { "role" => "tool", "tool_call_id" => "c2", "content" => "ok" }
    ])
  end

  it "parks an approval without executing its tool or requesting another completion" do
    guarded = tool("guarded") { raise "must not execute" }
    guarded.class.requires_approval
    chat.with_tools(guarded)
    chat.add_message(tool_message(call("c1", name: "guarded")))
    expect(chat.provider).not_to receive(:complete)
    expect(chat.awaiting_approval?).to be(true)
    expect(chat.complete?).to be(false)
    expect(chat.step).to be_nil
  end

  it "keeps a tail append in the next request without rewriting history" do
    chat.with_tools(tool("search") { "result" })
    chat.add_message(tool_message(call("c1")))
    original = chat.messages.first
    chat.after_message { |message| chat.add_message(role: :user, content: "Also this") if message.role == :tool }
    chat.step
    expect(chat.provider).to receive(:complete) do |messages, **|
      expect(messages.map(&:role)).to eq(%i[assistant tool user])
      expect(messages.last.content).to eq("Also this")
      RubyLLM::Message.new(role: :assistant, content: "Done")
    end
    chat.step
    expect(chat.messages.first).to equal(original)
  end

  it "passes tool_call context separately from provider arguments" do
    requested = call("context-id", arguments: { "query" => "value" })
    received = nil
    instance = tool("search") { |tool_call, arguments| received = [tool_call, arguments]; "ok" }
    envelope = Insika::ToolEnvelope.new(instance, state: state, checkpoint_store: Object.new,
                                        tool_registry: Object.new, timeout: 1)
    chat.with_tools(envelope)
    builder.wire_callbacks(chat, state, ->(*) {})
    chat.add_message(tool_message(requested))
    Sync { chat.run_tools }
    expect(received).to eq([requested, { query: "value" }])
    expect(instance.parameters_schema.fetch("properties")).not_to have_key("tool_call")
  end

  describe "fiber tool concurrency" do
    it "uses separate fibers and preserves callback correlation and completion order" do
      fibers = Hash.new { |hash, key| hash[key] = [] }
      order = []
      chat.with_tools(tool("search") do |item, _|
        fibers[item.id] << Fiber.current.object_id
        Async::Task.current.sleep(0.02) if item.id == "slow"
        item.id
      end).with_tool_options(concurrency: :fibers)
      chat.before_tool_call { |item| fibers[item.id] << Fiber.current.object_id }
      chat.after_tool_result { |result| fibers[result] << Fiber.current.object_id; order << result }
      chat.add_message(tool_message(call("slow"), call("fast")))
      chat.run_tools
      expect(chat.concurrency).to eq(:fibers)
      expect(fibers.values.map { |values| values.uniq.size }).to eq([1, 1])
      expect(fibers["slow"].first).not_to eq(fibers["fast"].first)
      expect(order).to eq(%w[fast slow])
      expect(chat.messages.last(2).map(&:tool_call_id)).to eq(%w[fast slow])
    end

    it "runs siblings before propagating a failed call" do
      ran = []
      chat.with_tools(tool("search") do |item, _|
        ran << item.id
        raise "boom" if item.id == "a"
        "ok"
      end).with_tool_options(concurrency: :fibers)
      chat.add_message(tool_message(call("a"), call("b"), call("c")))
      expect { chat.run_tools }.to raise_error("boom")
      expect(ran.sort).to eq(%w[a b c])
    end

    it "waits for in-flight tools before the enclosing timeout returns" do
      finished = false
      chat.with_tools(tool("search") do
        Async::Task.current.sleep(0.06)
        finished = true
        "ok"
      end).with_tool_options(concurrency: :fibers)
      chat.add_message(tool_message(call("a")))
      expect { Sync { |task| task.with_timeout(0.01) { chat.run_tools } } }.to raise_error(Async::TimeoutError)
      expect(finished).to be(true)
    end
  end

  it "marks only stable instructions as the cache boundary" do
    chat.with_instructions("Stable", cache_until_here: true)
    chat.with_instructions("Volatile", append: true)
    expect(chat.messages.map(&:content)).to eq(%w[Stable Volatile])
    expect(chat.messages.map(&:cache_until_here?)).to eq([true, false])
  end

  it "isolates context credentials and passes its current key to the provider" do
    previous = RubyLLM.config.deepseek_api_key
    context.config.deepseek_api_key = "rotated"
    expect(chat.provider.headers["Authorization"]).to eq("Bearer rotated")
    expect(RubyLLM.config.deepseek_api_key).to eq(previous)
  end

  it "preserves seeded tool calls and result ids exactly" do
    requested = call("stored-id", arguments: { "query" => "saved" })
    chat.add_message(role: :assistant, content: "", tool_calls: { "stored-id" => requested })
    chat.add_message(role: :tool, content: '{"found":true}', tool_call_id: "stored-id")
    expect(chat.messages.first.tool_calls.fetch("stored-id").arguments).to eq("query" => "saved")
    expect(chat.messages.last.tool_call_id).to eq("stored-id")
    expect(chat.messages.last.content).to eq('{"found":true}')
    expect(chat.complete?).to be(false)
  end

  it "exposes usage, model, and thinking through RubyLLM 2 value objects" do
    message = RubyLLM::Message.new(role: :assistant, content: "Done", model: "deepseek-chat",
                                  input_tokens: 12, output_tokens: 3, cache_read_tokens: 4, cache_write_tokens: 2)
    expect(message.tokens.input).to eq(12)
    expect(message.tokens.output).to eq(3)
    expect(message.tokens.cache_read).to eq(4)
    expect(message.tokens.cache_write).to eq(2)
    expect(message.model).to eq("deepseek-chat")
    expect(RubyLLM::Chunk.public_instance_methods).to include(:content, :thinking)
    expect(RubyLLM::Thinking.public_instance_methods).to include(:text)
  end

  it "requires a provider when bypassing model resolution" do
    expect { RubyLLM::Chat.new(model: "whisper-1", assume_model_exists: true) }.to raise_error(ArgumentError, /provider/i)
    config = RubyLLM.context { |value| value.openai_api_key = "spec-only" }.config
    expect { RubyLLM::Models.resolve("whisper-1", config: config) }.not_to raise_error
  end

  it "applies model parameters through methods the real Chat implements" do
    Insika::ModelSelection.new(model: "m", provider: :deepseek,
                              params: { temperature: 0.2, max_tokens: 200, thinking: "high" }).apply_params(chat)
    expect(chat.temperature).to eq(0.2)
    expect(chat.max_output_tokens).to eq(200)
    expect(chat.thinking[:effort]).to eq(:high)
  end

  describe "the shared chat double" do
    it "exposes only real Chat methods and declared test controls" do
      scaffolding = %i[asked completes instructions model= script script= final_content final_content=
                       fire_tool_call fire_tool_result fire_tool_result_message fire_end_message
                       emit_chunk emit_thinking halt_with!]
      expect(FakeChat.public_instance_methods(false) - scaffolding - RubyLLM::Chat.public_instance_methods).to be_empty
    end

    it "exposes only real message and thinking fields" do
      expect(FakeChat::Response.members - RubyLLM::Message.public_instance_methods).to be_empty
      expect(FakeChat::ThinkingChunk.members - RubyLLM::Message.public_instance_methods).to be_empty
      expect(FakeChat::Thought.members - RubyLLM::Thinking.public_instance_methods).to be_empty
    end
  end
end
