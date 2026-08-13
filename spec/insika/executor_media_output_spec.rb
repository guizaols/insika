# frozen_string_literal: true

require "spec_helper"
require "async"
require "insika/tools/generate_image"
require "insika/tools/tts"

# WS9 (saída): generated media as turn outputs. The model can only generate an
# image/audio clip when BOTH gates pass — the agent opted in (`outputs`) AND
# the channel declared it can receive the media (`channel.capabilities`). The
# generated part rides the terminal event (output_parts) and the usage is
# accounted (image tokens merged; an honest media counter for TTS). The
# generation seams are injected so nothing touches the network; the default
# provider path is lazy and untested here.
RSpec.describe "Insika::Executor + media output (WS9, saída)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }
  let(:profile) do
    Insika::AgentProfile.build(
      id: "a", model: "m",
      outputs: { "image" => { "model" => "gpt-image-1" }, "tts" => { "voice" => "nova" } }
    )
  end

  # The deterministic seam contract: ->(content, config) { [part, usage] }.
  # part carries its own "type"; usage carries the provider's token counts
  # (the speech API reports none — the TTS seam returns {}).
  let(:seams) do
    {
      image: lambda do |prompt, config|
        [ { "type" => "image", "mime_type" => "image/png", "base64" => "QUJD",
            "model" => "gpt-image-1" },
          { input_tokens: 5, output_tokens: 3 } ]
      end,
      tts: lambda do |text, config|
        [ { "type" => "audio", "mime_type" => "audio/mpeg", "base64" => "TVNE",
            "model" => "tts-1" },
          {} ]
      end
    }
  end

  def build_executor(media_output: nil)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([guardrails.input_guardrail]),
      hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      content_filter_factory: guardrails.content_filter_factory,
      media_output: media_output
    )
  end

  def task(message, channel: nil, id: "t-1")
    payload = { agent: "a", message: message }
    payload[:channel] = channel if channel
    task_store.create(command: Insika::Command.build(:send_message, payload).to_h,
                      session_id: "s1", id: id)
  end

  def run(executor, t, chat, profile: profile())
    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      executor.spawn(t, profile: profile)
      executor.instance_variable_get(:@running)[t.id]&.wait
    end
  end

  def completed(executor)
    event_stream.events.find { |e| e.type == :task_completed }.data
  end

  before { session_store.create(id: "s1") }

  it "BOTH gates off: a channel that declares nothing gets no media tools" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    run(executor, task("oi"), chat)

    expect(chat.tools.grep(Insika::Tools::GenerateImage)).to be_empty
    expect(chat.tools.grep(Insika::Tools::Tts)).to be_empty
  end

  it "agent gate off: profile without `outputs` never wires the tools, even with the capability" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    no_outputs = Insika::AgentProfile.build(id: "a", model: "m")
    run(executor, task("oi", channel: { capabilities: %w[image_output audio_output] }), chat,
        profile: no_outputs)

    expect(chat.tools.grep(Insika::Tools::GenerateImage)).to be_empty
    expect(chat.tools.grep(Insika::Tools::Tts)).to be_empty
  end

  it "channel gate on, agent on: generate_image is wired and only it" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    run(executor, task("oi", channel: { capabilities: %w[image_output] }), chat)

    expect(chat.tools.grep(Insika::Tools::GenerateImage).size).to eq(1)
    expect(chat.tools.grep(Insika::Tools::Tts)).to be_empty
  end

  it "the model generates an image -> the part rides the envelope and the tokens join the usage" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    chat.script = proc do
      tool = chat.tools.find { |t| t.is_a?(Insika::Tools::GenerateImage) }
      tool.execute(prompt: "a red sofa in a white room")
      emit_chunk("Here it is!")
    end

    run(executor, task("desenha um sofá", channel: { capabilities: %w[image_output] }), chat)

    data = completed(executor)
    expect(data[:output_parts]).to eq([
      { "type" => "image", "mime_type" => "image/png", "base64" => "QUJD", "model" => "gpt-image-1" }
    ])
    expect(data[:content]).to eq("Here it is!") # the media never becomes the answer text
    expect(data[:usage]).to include(input_tokens: 5, output_tokens: 3, total_tokens: 8, media: 1)
  end

  it "TTS: the clip rides the envelope; no invented token counts, but the call is counted" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    chat.script = proc do
      tool = chat.tools.find { |t| t.is_a?(Insika::Tools::Tts) }
      tool.execute(text: "Seu pedido chegou!")
      emit_chunk("Vou te mandar um áudio.")
    end

    run(executor, task("manda áudio", channel: { capabilities: %w[audio_output] }), chat)

    data = completed(executor)
    expect(data[:output_parts]).to eq([
      { "type" => "audio", "mime_type" => "audio/mpeg", "base64" => "TVNE", "model" => "tts-1" }
    ])
    expect(data[:usage]).to eq(media: 1) # no tokens (the speech API reports none) — honest
  end

  it "two parts in one turn: both ride the envelope, one counter per call" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    chat.script = proc do
      img = chat.tools.find { |t| t.is_a?(Insika::Tools::GenerateImage) }
      img.execute(prompt: "sofa")
      tts = chat.tools.find { |t| t.is_a?(Insika::Tools::Tts) }
      tts.execute(text: "pronto!")
      emit_chunk("pronto!")
    end

    run(executor, task("faz tudo", channel: { capabilities: %w[image_output audio_output] }), chat)

    data = completed(executor)
    expect(data[:output_parts].map { |p| p["type"] }).to eq(%w[image audio])
    expect(data[:usage]).to include(media: 2, input_tokens: 5, output_tokens: 3)
  end

  it "a turn that generates nothing carries no output_parts (parity)" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    run(executor, task("oi", channel: { capabilities: %w[image_output] }), chat)

    expect(completed(executor)).not_to have_key(:output_parts)
  end
end
