# frozen_string_literal: true

require "spec_helper"
require "async"

# WS9 (input half): content parts on the message become a turn — audio is
# transcribed (text enters the message marked `source: :voice`), image parts
# attach to the model ask. The STT seam is injected so nothing touches the
# network; the real fetch+RubyLLM path is the default, lazy and untested here.
RSpec.describe "Insika::Executor + media (WS9)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }
  let(:profile) { Insika::AgentProfile.build(id: "a", model: "m") }

  def build_executor(media: nil)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([guardrails.input_guardrail]),
      hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      content_filter_factory: guardrails.content_filter_factory, media: media
    )
  end

  def task(message, parts: nil, source: nil, id: "t-1")
    payload = { agent: "a", message: message }
    payload[:parts] = parts if parts
    payload[:source] = source if source
    task_store.create(command: Insika::Command.build(:send_message, payload).to_h,
                      session_id: "s1", id: id)
  end

  def run(executor, t, chat)
    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      executor.spawn(t, profile: profile)
      executor.instance_variable_get(:@running)[t.id]&.wait
    end
  end

  before { session_store.create(id: "s1") }

  it "an AUDIO part is transcribed — the text enters the message and the turn is marked source: voice" do
    executor = build_executor(media: ->(_url) { "quero saber do meu pedido" })
    chat = FakeChat.new
    run(executor, task("", parts: [{ "type" => "audio", "url" => "https://cdn.example.com/voz.ogg" }]), chat)

    expect(chat.asked).to eq("quero saber do meu pedido")
    completed = event_stream.events.find { |e| e.type == :task_completed }
    expect(completed.data[:source]).to eq(:voice)
  end

  it "an IMAGE part attaches to the ask — the model sees it, the usage flows like any ask" do
    attachment = Object.new
    executor = build_executor
    allow(executor).to receive(:media_attachment).and_return(attachment)
    chat = FakeChat.new
    run(executor, task("foto aqui", parts: [{ "type" => "image", "url" => "https://cdn.example.com/foto.png" }]), chat)

    expect(chat.instance_variable_get(:@attachments)).to eq([attachment])
    expect(chat.asked).to eq("foto aqui")
  end

  it "an IMAGE part whose URL the egress guard blocks fails the turn at :media (SSRF)" do
    executor = build_executor
    chat = FakeChat.new
    run(executor, task("foto aqui", parts: [{ "type" => "image", "url" => "http://169.254.169.254/latest/meta-data" }]), chat)

    failed = task_store.find("t-1")
    expect(failed.status).to eq(:failed)
    expect(failed.executions.last.error["stage"]).to eq("media")
  end

  it "a text + image + audio mix: message = typed text + transcription, image attached" do
    executor = build_executor(media: ->(_url) { "a cor do sofá" })
    allow(executor).to receive(:media_attachment).and_return(Object.new)
    chat = FakeChat.new
    run(executor, task("me ajuda", parts: [
                          { "type" => "text", "text" => "me ajuda" },
                          { "type" => "image", "url" => "https://cdn.example.com/sofa.png" },
                          { "type" => "audio", "url" => "https://cdn.example.com/voz.ogg" }
                        ]), chat)

    expect(chat.asked).to eq("me ajuda\na cor do sofá")
    expect(chat.instance_variable_get(:@attachments).size).to eq(1)
  end

  it "source: voice WITHOUT parts marks the turn (a consumer's own transcription)" do
    executor = build_executor
    chat = FakeChat.new
    run(executor, task("cadê meu pedido", source: "voice"), chat)

    completed = event_stream.events.find { |e| e.type == :task_completed }
    expect(completed.data[:source]).to eq(:voice)
  end
end