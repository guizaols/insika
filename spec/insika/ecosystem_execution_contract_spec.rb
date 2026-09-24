# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/insika/telemetry/ruby_llm_instrumenter"

RSpec.describe "RubyLLM execution replacement gates" do
  let(:context) do
    RubyLLM.context do |config|
      config.deepseek_api_key = "spec-only"
      config.deepseek_api_base = "https://api.deepseek.com"
      config.max_retries = 1
      config.retry_interval = 0
      config.retry_interval_randomness = 0
    end
  end
  let(:chat) { context.chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true) }

  def guarded_tool(&implementation)
    Class.new(RubyLLM::Tool) do
      requires_approval
      define_method(:name) { "write" }
      define_method(:execute, &implementation)
    end.new
  end

  def pending_message
    RubyLLM::Message.new(role: :assistant, content: "",
      tool_calls: { "write-1" => RubyLLM::ToolCall.new(id: "write-1", name: "write", arguments: {}) })
  end

  def restored_chat(source)
    context.chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true).tap do |restored|
      JSON.parse(JSON.generate(source.messages.map(&:to_h))).each do |message|
        restored.add_message(message.transform_keys(&:to_sym))
      end
    end
  end

  it "makes exactly two physical transport attempts for one native retry" do
    transport = RubyLLM::Transport::Connection.new(chat.provider, context.config)
    attempts = 0
    transport.connection.adapter :test do |stub|
      stub.post("/probe") do
        attempts += 1
        raise Faraday::ConnectionFailed, "offline" if attempts == 1
        [200, { "Content-Type" => "application/json" }, '{"ok":true}']
      end
    end

    expect(transport.post("probe", {}).body).to eq("ok" => true)
    expect(attempts).to eq(2)
  end

  it "does not retry a transport failure after streamed output was delivered" do
    transport = RubyLLM::Transport::Connection.new(chat.provider, context.config)
    attempts = 0
    transport.connection.adapter :test do |stub|
      stub.post("/probe") do
        attempts += 1
        raise Faraday::ConnectionFailed, "stream interrupted"
      end
    end

    expect do
      transport.post("probe", {}) do |request|
        request.options.context = { RubyLLM::Transport::Connection::STREAM_PROGRESS_KEY => { started: true } }
      end
    end.to raise_error(Faraday::ConnectionFailed)
    expect(attempts).to eq(1)
  end

  it "reports native retry attempts as usage events without their failure exception" do
    events = []
    instrumenter = Object.new
    instrumenter.define_singleton_method(:instrument) do |name, payload, &block|
      result = block&.call
      events << [name, payload.dup]
      result
    end
    context.config.instrumenter = instrumenter
    attempts = 0
    allow_any_instance_of(RubyLLM::Transport::Connection).to receive(:post).and_wrap_original do |original, *args, **kwargs, &block|
      original.receiver.connection.adapter :test do |stub|
        stub.post("/chat/completions") do
          attempts += 1
          raise Faraday::ConnectionFailed, "offline" if attempts == 1

          [200, { "Content-Type" => "application/json" }, JSON.generate(
            model: "deepseek-chat", choices: [{ message: { role: "assistant", content: "Done" } }],
            usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 })]
        end
      end
      original.call(*args, **kwargs, &block)
    end

    expect(chat.ask("hello").content).to eq("Done")
    expect(attempts).to eq(2)
    expect(events.count { |name, _| name == "request.ruby_llm" }).to eq(1)
    usage = events.filter_map { |name, payload| payload if name == "usage.ruby_llm" }
    expect(usage.map { |payload| payload[:status] }).to eq(%i[failed succeeded])
    expect(usage.first.keys).to contain_exactly(:operation, :provider, :model, :status, :tokens, :cost)
  end

  it "bridges a native retry as one request and two correlated usage attempts" do
    events = []
    context.config.instrumenter = Insika::Telemetry::RubyLLMInstrumenter.new(
      emit: ->(type, data) { events << [type, data] }, operation: "chat", model: "deepseek-chat")
    attempts = 0
    allow_any_instance_of(RubyLLM::Transport::Connection).to receive(:post).and_wrap_original do |original, *args, **kwargs, &block|
      original.receiver.connection.adapter :test do |stub|
        stub.post("/chat/completions") do
          attempts += 1
          raise Faraday::TimeoutError, "private provider detail" if attempts == 1
          [200, { "Content-Type" => "application/json" }, JSON.generate(
            model: "deepseek-chat", choices: [{ message: { role: "assistant", content: "Done" } }],
            usage: { prompt_tokens: 7, completion_tokens: 2, total_tokens: 9 })]
        end
      end
      original.call(*args, **kwargs, &block)
    end

    expect(chat.ask("private user prompt").content).to eq("Done")
    requests = events.select { |type, _| type == :llm_request }.map(&:last)
    usage = events.select { |type, _| type == :llm_usage }.map(&:last)
    expect(attempts).to eq(2)
    expect(requests.size).to eq(1)
    expect(usage.map { |row| row["status"] }).to eq(%w[failed succeeded])
    expect(usage.map { |row| row["request_id"] }).to eq([requests.first["request_id"]] * 2)
    expect(usage.first).to include("input_tokens" => nil, "output_tokens" => nil, "cost" => nil)
    expect(usage.last).to include("input_tokens" => 7, "output_tokens" => 2)
    expect(usage).to all(satisfy { |row| !row.key?("duration_ms") && !row.key?("exception_class") })
    expect(JSON.generate(events)).not_to include("private", "Done", "api.deepseek.com")
  end

  it "attributes requests to the active native fallback model and clears completed correlation" do
    events = []
    context.config.max_retries = 0
    bridge = Insika::Telemetry::RubyLLMInstrumenter.new(
      emit: ->(type, data) { events << [type, data] }, operation: "chat", model: "deepseek-chat")
    context.config.instrumenter = bridge
    chat.with_fallbacks(RubyLLM::Model.new(id: "deepseek-reasoner", provider: "deepseek"))
    allow_any_instance_of(RubyLLM::Transport::Connection).to receive(:post).and_wrap_original do |original, *args, **kwargs, &block|
      original.receiver.connection.adapter :test do |stub|
        stub.post("/chat/completions") do |env|
          model = JSON.parse(env.body).fetch("model")
          raise RubyLLM::ServerError, "private" if model == "deepseek-chat"
          [200, { "Content-Type" => "application/json" }, JSON.generate(
            model: model, choices: [{ message: { role: "assistant", content: "Done" } }],
            usage: { prompt_tokens: 1, completion_tokens: 1 })]
        end
      end
      original.call(*args, **kwargs, &block)
    end
    expect(chat.ask("private").content).to eq("Done")
    requests = events.select { |type, _| type == :llm_request }.map(&:last)
    expect(requests.map { |row| row["model"] }).to eq(%w[deepseek-chat deepseek-reasoner])
    expect(requests.map { |row| row["status"] }).to eq(%w[failed succeeded])
    expect(requests.map { |row| row["request_id"] }.uniq.size).to eq(2)
    bridge.instrument("usage.ruby_llm", operation: :embedding, model: "auxiliary")
    expect(events.last.last["request_id"]).to be_nil
  end

  it "restores the primary model after fallback and uses it for the next generation" do
    chat.with_fallbacks(RubyLLM::Model.new(id: "deepseek-reasoner", provider: "deepseek"))
    primary = chat.provider
    fallback = RubyLLM::Providers::DeepSeek.new(context.config)
    allow(RubyLLM::Providers::DeepSeek).to receive(:new).and_return(fallback)
    primary_attempts = 0
    expect(primary).to receive(:complete).twice do |*, **|
      primary_attempts += 1
      raise Faraday::ConnectionFailed, "offline" if primary_attempts == 1

      RubyLLM::Message.new(role: :assistant, content: "Primary answered")
    end
    expect(fallback).to receive(:complete).once.and_return(
      RubyLLM::Message.new(role: :assistant, content: "Fallback answered"))

    expect(chat.ask("hello").content).to eq("Fallback answered")
    expect(chat.model.id).to eq("deepseek-chat")
    expect(chat.provider).to equal(primary)
    expect(chat.ask("continue").content).to eq("Primary answered")
  end

  it "counts multiplied physical attempts when native retries run inside Reliability" do
    transport = RubyLLM::Transport::Connection.new(chat.provider, context.config)
    attempts = 0
    transport.connection.adapter :test do |stub|
      stub.post("/probe") do
        attempts += 1
        raise RubyLLM::ServerError, "offline"
      end
    end
    reliability = Insika::Reliability.new(circuit_store: Object.new,
      event_stream: Insika::EventStream.new, sleeper: ->(*) {})
    expect do
      reliability.call(policy: { "retries" => 1 }, tenant: nil,
        selection: Insika::ModelSelection.new(model: "deepseek-chat", provider: :deepseek), chain: []) do
        transport.post("probe", {})
      end
    end.to raise_error(RubyLLM::ServerError)
    expect(attempts).to eq(4)
  end

  it "falls back after a completed external effect without running the tool again" do
    writes = 0
    writer = guarded_tool { writes += 1; "written" }
    chat.with_tools(writer).with_fallbacks(RubyLLM::Model.new(id: "deepseek-reasoner", provider: "deepseek"))
    chat.add_message(pending_message)
    chat.approve("write-1")
    chat.run_tools
    expect(writes).to eq(1)
    primary = chat.provider
    fallback = RubyLLM::Providers::DeepSeek.new(context.config)
    allow(RubyLLM::Providers::DeepSeek).to receive(:new).and_return(fallback)
    expect(primary).to receive(:complete).once.and_raise(Faraday::ConnectionFailed, "offline")
    expect(fallback).to receive(:complete).once do |messages, **|
      expect(messages.last.tool_call_id).to eq("write-1")
      expect(messages.last.content).to eq("written")
      RubyLLM::Message.new(role: :assistant, content: "Done")
    end

    expect(chat.step.content).to eq("Done")
    expect(writes).to eq(1)
    expect(chat.messages.count { |message| message.role == :tool }).to eq(1)
  end

  it "reports partial output when native fallback switches after streaming has started" do
    chat.with_fallbacks(RubyLLM::Model.new(id: "deepseek-reasoner", provider: "deepseek"))
    primary = chat.provider
    fallback = RubyLLM::Providers::DeepSeek.new(context.config)
    allow(RubyLLM::Providers::DeepSeek).to receive(:new).and_return(fallback)
    expect(primary).to receive(:complete) do |*, **, &on_chunk|
      on_chunk.call(RubyLLM::Chunk.new(role: :assistant, content: "partial"))
      raise Faraday::ConnectionFailed, "interrupted"
    end
    expect(fallback).to receive(:complete) do |*, **, &on_chunk|
      on_chunk.call(RubyLLM::Chunk.new(role: :assistant, content: "replacement"))
      RubyLLM::Message.new(role: :assistant, content: "replacement")
    end
    switched = []
    chunks = []
    chat.before_fallback { |event| switched << event.chunks_yielded? }

    chat.ask("hello") { |chunk| chunks << chunk.content }
    expect(switched).to eq([true])
    expect(chunks).to eq(%w[partial replacement])
  end

  it "can disable nested retries without mutating the shared credential context" do
    isolated = RubyLLM::Context.new(context.config.dup)
    isolated.config.max_retries = 0
    chat.with_context(isolated)

    expect(chat.context.config.max_retries).to eq(0)
    expect(context.config.max_retries).to eq(1)
    expect(chat.provider.headers.fetch("Authorization")).to eq("Bearer spec-only")
  end

  it "limits Insika reliable turns to their configured physical attempts without changing shared configuration" do
    attempts = 0
    allow_any_instance_of(RubyLLM::Transport::Connection).to receive(:post).and_wrap_original do |original, *args, **kwargs, &block|
      original.receiver.connection.adapter :test do |stub|
        stub.post("/chat/completions") do
          attempts += 1
          raise RubyLLM::ServerError, "offline"
        end
      end
      original.call(*args, **kwargs, &block)
    end
    executor = Insika::Executor.allocate
    circuits = Insika::CircuitState.new(store: Insika::Stores::Memory.new)
    events = SpyEventStream.new
    executor.instance_variable_set(:@reliability, Insika::Reliability.new(circuit_store: circuits,
      event_stream: events, sleeper: ->(*) {}))
    profile = Insika::AgentProfile.build(id: "a", model: "deepseek-chat", reliability: {
      "retries" => 1, "circuit_breaker" => { "after" => 2, "within" => 60, "cooldown" => 300 }
    })
    state = Insika::TurnState.new(task: nil, profile: profile, turn: 1, message: "hello")
    state.model_selection = Insika::ModelSelection.new(model: "deepseek-chat", provider: :deepseek)
    state.chat = chat
    allow(executor).to receive(:build_attempt_chat) do
      context.chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true)
    end
    allow(executor).to receive(:new_turn_output).and_return(Object.new)
    allow(executor).to receive(:wire_chat_output)
    allow(executor).to receive(:ask_on) { |_, _, current, *| current.ask("hello") }
    task = Struct.new(:command).new({})

    expect { executor.send(:run_reliable_ask, task, state, nil, nil) }.to raise_error(RubyLLM::ServerError)
    expect(attempts).to eq(2)
    expect(context.config.max_retries).to eq(1)
    expect(state.chat.context.config.max_retries).to eq(1)
    expect(state.chat.context.config.request_timeout).to eq(Insika::Reliability::DEFAULT_TIMEOUT)
    expect(executor).not_to have_received(:build_attempt_chat)
    expect(state.chat.provider.headers.fetch("Authorization")).to eq("Bearer spec-only")
    expect(events.events.count { |event| event.type == :provider_failure }).to eq(1)
    expect(circuits.state(tenant: nil, ref: "deepseek/deepseek-chat", after: 2)).to eq(:closed)
    expect { executor.send(:run_reliable_ask, task, state, nil, nil) }.to raise_error(RubyLLM::ServerError)
    expect(attempts).to eq(4)
    expect(circuits.state(tenant: nil, ref: "deepseek/deepseek-chat", after: 2)).to eq(:open)
    expect(circuits.state(tenant: "other", ref: "deepseek/deepseek-chat", after: 2)).to eq(:closed)
    expect { executor.send(:run_reliable_ask, task, state, nil, nil) }.to raise_error(Insika::CircuitOpenError)
    expect(attempts).to eq(4)
  end

  it "does not add an Insika retry after native transport has delivered stream data" do
    attempts = 0
    allow_any_instance_of(RubyLLM::Transport::Connection).to receive(:post).and_wrap_original do |original, *args, **kwargs, &block|
      original.receiver.connection.adapter :test do |stub|
        stub.post("/chat/completions") do |env|
          attempts += 1
          env.request.context ||= {}
          env.request.context[RubyLLM::Transport::Connection::STREAM_PROGRESS_KEY] = { started: true }
          raise Faraday::ConnectionFailed, "interrupted stream"
        end
      end
      original.call(*args, **kwargs, &block)
    end
    executor = Insika::Executor.allocate
    executor.instance_variable_set(:@reliability, Insika::Reliability.new(circuit_store: Object.new,
      event_stream: Insika::EventStream.new, sleeper: ->(*) {}))
    profile = Insika::AgentProfile.build(id: "a", reliability: { "retries" => 2 })
    state = Insika::TurnState.new(task: nil, profile: profile, turn: 1, message: "hello")
    state.model_selection = Insika::ModelSelection.new(model: "deepseek-chat", provider: :deepseek)
    state.chat = chat
    allow(executor).to receive(:build_attempt_chat) { context.chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true) }
    allow(executor).to receive(:new_turn_output).and_return(Object.new)
    allow(executor).to receive(:wire_chat_output)
    allow(executor).to receive(:ask_on) { |_, _, current, *| current.ask("hello") {} }

    expect { executor.send(:run_reliable_ask, Struct.new(:command).new({}), state, nil, nil) }
      .to raise_error(Faraday::ConnectionFailed)
    expect(attempts).to eq(1)
  end

  it "requires an external approval resolver to preserve a decision across JSON reload" do
    writes = 0
    writer = guarded_tool { writes += 1; "written" }
    chat.with_tools(writer).add_message(pending_message)
    chat.approve("write-1")
    restored = restored_chat(chat).with_tools(writer)

    expect(restored.awaiting_approval?).to be(true)
    expect(restored.step).to be_nil
    expect(writes).to eq(0)
    restored.approve("write-1")
    restored.run_tools
    expect(writes).to eq(1)
    expect(restored_chat(restored).with_tools(writer).pending_approvals).to be_empty
  end

  it "restores a denied approval without executing its tool" do
    writer = guarded_tool { raise "must not write" }
    chat.with_tools(writer).add_message(pending_message)
    restored = restored_chat(chat).with_tools(writer)
    restored.deny("write-1")
    restored.run_tools

    expect(restored.messages.last.content).to include("denied")
    expect(restored.messages.last.tool_call_id).to eq("write-1")
  end

  it "preserves opaque compaction content through native JSON message serialization" do
    opaque = [{ "type" => "compaction", "encrypted_content" => "provider-bound-state" }]
    chat.add_message(role: :assistant, content: "", raw_content: opaque)

    expect(restored_chat(chat).messages.last.raw_content).to eq(opaque)
  end

  it "omits opaque provider state from ordinary persisted history" do
    opaque = [{ "type" => "compaction", "encrypted_content" => "provider-bound-state" }]
    message = RubyLLM::Message.new(role: :assistant, content: "", raw_content: opaque)
    serialized = Insika::Executor.allocate.send(:serialize_chat_message, message)

    expect(serialized).to eq("role" => "assistant", "content" => "")
    expect(serialized).not_to have_key("raw_content")
  end

  describe "Insika fallback policy" do
    let(:profile) do
      Insika::AgentProfile.build(id: "a", model: "deepseek-chat", provider: "deepseek",
        reliability: { "fallback" => ["openai/gpt-4o-mini"] },
        model_policy: { "allow" => ["deepseek/deepseek-chat"] })
    end
    let(:state) { Insika::TurnState.new(task: nil, profile: profile, turn: 1, message: "hello") }

    it "never rotates a session-pinned model through profile fallbacks" do
      state.model_selection = Insika::ModelSelection.new(model: "deepseek-chat", provider: :deepseek, pinned: true)
      expect(Insika::Executor.allocate.send(:reliability_chain, state)).to be_empty
    end

    it "filters profile fallbacks through the agent model allowlist" do
      state.model_selection = Insika::ModelSelection.new(model: "deepseek-chat", provider: :deepseek)
      expect(Insika::Executor.allocate.send(:reliability_chain, state)).to be_empty
    end

    it "resolves bare fallback providers before checking provider allowlists" do
      profile = Insika::AgentProfile.build(id: "a", model: "deepseek-chat",
        reliability: { "fallback" => ["gpt-4o-mini", "missing-contract-model"] },
        model_policy: { "allow" => ["deepseek/*", "openai/*"] })
      state = Insika::TurnState.new(task: nil, profile: profile, turn: 1, message: "hello")
      state.model_selection = Insika::ModelSelection.new(model: "deepseek-chat", provider: :deepseek)

      chain = Insika::Executor.allocate.send(:reliability_chain, state)
      expect(chain.map { |selection| [selection.model, selection.provider.to_s] }).to eq([["gpt-4o-mini", "openai"]])
    end
  end
end
