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

  it "an IMAGE part attaches to the ask — the model sees it and the provider's tokens land on the turn" do
    attachment = Object.new
    executor = build_executor
    allow(executor).to receive(:media_attachment).and_return(attachment)
    chat = FakeChat.new
    def chat.ask(message, with: nil, &on_chunk)
      super
      Struct.new(:content, :input_tokens, :output_tokens, :model_id)
            .new(@final_content, 80, 12, "vision-m")
    end
    run(executor, task("foto aqui", parts: [{ "type" => "image", "url" => "https://cdn.example.com/foto.png" }]), chat)

    expect(chat.instance_variable_get(:@attachments)).to eq([attachment])
    expect(chat.asked).to eq("foto aqui")
    completed = event_stream.events.find { |e| e.type == :task_completed }
    expect(completed.data[:usage]).to include(input_tokens: 80, output_tokens: 12, total_tokens: 92)
  end

  it "an IMAGE part is deposited as ctx.image_url for data/HTTP tools" do
    executor = build_executor
    allow(executor).to receive(:media_attachment).and_return(Object.new)
    state = Insika::TurnState.new(task: nil, profile: profile, turn: 1, message: "foto")
    state.turn_context = { chat_id: "s1" }
    t = task("foto", parts: [{ "type" => "image", "url" => "https://cdn.example.com/foto.png" }])

    executor.send(:run_media_stage, t, state)

    expect(state.turn_context[:image_url]).to eq("https://cdn.example.com/foto.png")
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

  # RubyLLM's Attachment fetches a URL with `fetch_content`, which reads the
  # whole response with no ceiling: a hostile URL grows THIS process until it
  # dies. The bytes come through our capped, egress-guarded fetch instead.
  it "an image is fetched through the CAPPED fetch — the gem never holds the URL" do
    require "ruby_llm"
    png = "\x89PNG\r\n\x1a\n".b + ("x" * 64)
    expect(Insika::Media).to receive(:fetch_binary)
      .with("https://cdn.example.com/foto.png", max_bytes: Insika::Media::MAX_IMAGE_BYTES)
      .and_return(png)

    attachment = build_executor.send(:media_attachment, "https://cdn.example.com/foto.png")

    expect(attachment.url?).to be(false) # nothing left for the gem to fetch
    expect(attachment.content).to eq(png)
    expect(attachment.mime_type).to eq("image/png")
  end

  it "an image PAST the cap fails the turn at :media (the process is not the buffer)" do
    executor = build_executor
    allow(Insika::Media).to receive(:fetch_binary)
      .and_raise(Insika::MediaError, "media exceeds #{Insika::Media::MAX_IMAGE_BYTES} bytes")
    run(executor, task("olha isso", parts: [{ "type" => "image", "url" => "https://cdn.example.com/huge.png" }]),
        FakeChat.new)

    failed = task_store.find("t-1")
    expect(failed.status).to eq(:failed)
    expect(failed.executions.last.error["stage"]).to eq("media")
  end

  # An image with no caption asks with NIL, not "": nil is how RubyLLM says
  # "attachments only", and an empty text part is a thing providers refuse.
  it "an IMAGE with no caption asks with the attachment and no text" do
    executor = build_executor
    allow(executor).to receive(:media_attachment).and_return(Object.new)
    chat = FakeChat.new
    run(executor, task("", parts: [{ "type" => "image", "url" => "https://cdn.example.com/foto.png" }]), chat)

    expect(chat.asked).to be_nil
    expect(chat.instance_variable_get(:@attachments).size).to eq(1)
    expect(task_store.find("t-1").status).to eq(:completed)
  end

  # A voice note we could not hear must not become an empty turn sent to the
  # provider — the customer would get an answer to nothing.
  it "a media-only turn whose transcription comes back EMPTY fails at :media" do
    executor = build_executor(media: ->(_url) { "" })
    run(executor, task("", parts: [{ "type" => "audio", "url" => "https://cdn.example.com/voz.ogg" }]),
        FakeChat.new)

    failed = task_store.find("t-1")
    expect(failed.status).to eq(:failed)
    expect(failed.executions.last.error["stage"]).to eq("media")
  end

  it "source: voice WITHOUT parts marks the turn (a consumer's own transcription)" do
    executor = build_executor
    chat = FakeChat.new
    run(executor, task("cadê meu pedido", source: "voice"), chat)

    completed = event_stream.events.find { |e| e.type == :task_completed }
    expect(completed.data[:source]).to eq(:voice)
  end
end