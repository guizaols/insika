# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Executor native chat reliability" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:checkpoints) { Insika::CheckpointStore.new(store: backend) }
  let(:events) { SpyEventStream.new }
  let(:reliability) do
    Insika::Reliability.new(circuit_store: Insika::CircuitState.new(store: backend),
      event_stream: events, sleeper: ->(*) {})
  end
  let(:context) do
    RubyLLM.context do |config|
      config.deepseek_api_key = "spec-only"
      config.deepseek_api_base = "https://api.deepseek.com"
      config.retry_interval = 0
      config.retry_interval_randomness = 0
    end
  end
  let(:writes) { [] }
  let(:writer) do
    sink = writes
    Class.new(RubyLLM::Tool) do
      def name = "write"
      define_method(:execute) { sink << "written"; "written" }
    end.new
  end
  let(:profile) do
    Insika::AgentProfile.build(id: "a", model: "deepseek-v4-flash", provider: "deepseek",
      tools_allow: ["write"], reliability: policy)
  end
  let(:policy) { { "retries" => 1, "fallback" => ["deepseek/deepseek-v4-pro"] } }
  let(:runtime) do
    Insika::Executor.new(context_builder: FakeContextBuilder.new,
      policy_engine: double(decide: Resolution.new([writer], [], [])),
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new(side_effect_names: ["write"]), skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "a" => profile }, session_store: sessions, task_store: tasks,
      checkpoint_store: checkpoints, event_stream: events, llm: context,
      content_filter_factory: Insika::Safety::Factory.new.content_filter_factory, reliability: reliability)
  end

  def response(text)
    RubyLLM::Message.new(role: :assistant, content: text, input_tokens: 5, output_tokens: 1)
  end

  def run_turn
    sessions.create(id: "s")
    task = tasks.create(id: "t", session_id: "s", command: Insika::Command.build(:send_message,
      { agent: "a", message: "please write" }).to_h)
    Sync do
      runtime.spawn(task, profile: profile)
      runtime.instance_variable_get(:@running)["t"]&.wait
    end
    expect(tasks.find("t").status).to eq(:completed), tasks.find("t").inspect
    events.events.find { |event| event.type == :task_completed }.data
  end

  [{ "retries" => 1 }, { "retries" => 0, "fallback" => ["deepseek/deepseek-v4-pro"] }].each do |settings|
    context "with #{settings.inspect}" do
      let(:policy) { settings }

      it "continues after an ungated write without asking the model to regenerate the call" do
        attempts = 0
        transport_attempts = 0
        restored = nil
        allow_any_instance_of(RubyLLM::Providers::DeepSeek).to receive(:complete) do |provider, messages, **, &stream|
          attempts += 1
          if attempts == 1
            RubyLLM::Message.new(role: :assistant, content: "", input_tokens: 10, output_tokens: 2,
              tool_calls: { "write-1" => RubyLLM::ToolCall.new(id: "write-1", name: "write", arguments: {}) })
          else
            if settings["retries"].positive?
              transport = provider.connection
              transport.connection.adapter :test do |stub|
                stub.post("/probe") do
                  transport_attempts += 1
                  raise Faraday::ConnectionFailed, "interrupted after write" if transport_attempts == 1
                  [200, { "Content-Type" => "application/json" }, '{}']
                end
              end
              transport.post("probe", {})
            elsif attempts == 2
              raise Faraday::ConnectionFailed, "interrupted after write"
            end
            restored = messages.map(&:to_h)
            stream.call(RubyLLM::Chunk.new(role: :assistant, content: "done"))
            response("done")
          end
        end

        completed = run_turn
        expect(restored.last).to include(role: :tool, content: "written", tool_call_id: "write-1")
        expect(restored.count { |message| message[:role] == :user }).to eq(1)
        expect(writes).to eq(["written"])
        expect(completed.fetch(:usage)).to include(input_tokens: 15, output_tokens: 3)
        expect(attempts).to eq(settings["retries"].positive? ? 2 : 3)
        expect(transport_attempts).to eq(2) if settings["retries"].positive?
      end
    end
  end

  it "does not prepend the failed stream's redactor tail to the replacement answer" do
    attempts = 0
    models = []
    allow_any_instance_of(RubyLLM::Providers::DeepSeek).to receive(:complete) do |_, *, model:, **, &stream|
      attempts += 1
      models << model.id
      if attempts == 1
        stream.call(RubyLLM::Chunk.new(role: :assistant, content: "sk-unfinished"))
        raise Faraday::ConnectionFailed, "interrupted stream"
      end
      stream.call(RubyLLM::Chunk.new(role: :assistant, content: "replacement"))
      response("replacement")
    end

    expect(run_turn.fetch(:content)).to eq("replacement")
    expect(attempts).to eq(2)
    expect(models).to eq(%w[deepseek-v4-flash deepseek-v4-pro])
    expect(events.events.count { |event| event.type == :provider_failure }).to eq(1)
  end
end
