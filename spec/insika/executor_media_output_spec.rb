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

  def task(message, channel: nil, parts: nil, id: "t-1")
    payload = { agent: "a", message: message }
    payload[:channel] = channel if channel
    payload[:parts] = parts if parts
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

  it "a non-Hash outputs entry never wires the tool (safe parity, no turn crash)" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    weird = Insika::AgentProfile.build(id: "a", model: "m", outputs: { "image" => true })
    run(executor, task("oi", channel: { capabilities: %w[image_output] }), chat,
        profile: weird)

    expect(chat.tools.grep(Insika::Tools::GenerateImage)).to be_empty
    expect(completed(executor)).to have_key(:content)
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

  # RFC-0042 PR1: generate_image can EDIT — explicit source_image_urls, or
  # (absent those) the turn's own inbound photo, ride the seam's config.
  describe "image editing" do
    def capturing_seams(base)
      captured = {}
      seams = base.merge(
        image: lambda do |prompt, config|
          captured[:config] = config
          base[:image].call(prompt, config)
        end
      )
      [seams, captured]
    end

    it "explicit source_image_urls ride the config as source_urls" do
      wired, captured = capturing_seams(seams)
      executor = build_executor(media_output: wired)
      chat = FakeChat.new
      chat.script = proc do
        tool = chat.tools.find { |t| t.is_a?(Insika::Tools::GenerateImage) }
        tool.execute(prompt: "put this shirt on the model",
                     source_image_urls: ["https://cdn.example.com/produto.png"])
        emit_chunk("pronto")
      end

      run(executor, task("edita essa foto", channel: { capabilities: %w[image_output] }), chat)

      expect(captured[:config]["source_urls"]).to eq(["https://cdn.example.com/produto.png"])
      expect(captured[:config]).not_to have_key("source_attachments")
    end

    it "no explicit URLs, but the turn carries an inbound photo: it becomes the default edit source" do
      wired, captured = capturing_seams(seams)
      executor = build_executor(media_output: wired)
      allow(executor).to receive(:media_attachment).and_return(:the_inbound_attachment)
      chat = FakeChat.new
      chat.script = proc do
        tool = chat.tools.find { |t| t.is_a?(Insika::Tools::GenerateImage) }
        tool.execute(prompt: "coloca esse tênis no meu pé")
        emit_chunk("pronto")
      end

      run(executor,
          task("", channel: { capabilities: %w[image_output] },
               parts: [{ "type" => "image", "url" => "https://cdn.example.com/pe.png" }]), chat)

      expect(captured[:config]["source_attachments"]).to eq([:the_inbound_attachment])
    end

    it "explicit source_image_urls win over the turn's own inbound photo" do
      wired, captured = capturing_seams(seams)
      executor = build_executor(media_output: wired)
      allow(executor).to receive(:media_attachment).and_return(:the_inbound_attachment)
      chat = FakeChat.new
      chat.script = proc do
        tool = chat.tools.find { |t| t.is_a?(Insika::Tools::GenerateImage) }
        tool.execute(prompt: "usa essa outra foto", source_image_urls: ["https://cdn.example.com/outra.png"])
        emit_chunk("pronto")
      end

      run(executor,
          task("", channel: { capabilities: %w[image_output] },
               parts: [{ "type" => "image", "url" => "https://cdn.example.com/pe.png" }]), chat)

      expect(captured[:config]["source_urls"]).to eq(["https://cdn.example.com/outra.png"])
      expect(captured[:config]).not_to have_key("source_attachments")
    end

    it "no sources at all (plain generation): the config carries neither key — byte-identical" do
      wired, captured = capturing_seams(seams)
      executor = build_executor(media_output: wired)
      chat = FakeChat.new
      chat.script = proc do
        tool = chat.tools.find { |t| t.is_a?(Insika::Tools::GenerateImage) }
        tool.execute(prompt: "a red sofa")
        emit_chunk("pronto")
      end

      run(executor, task("desenha um sofá", channel: { capabilities: %w[image_output] }), chat)

      expect(captured[:config]).not_to have_key("source_urls")
      expect(captured[:config]).not_to have_key("source_attachments")
    end
  end

  it "a turn that generates nothing carries no output_parts (parity)" do
    executor = build_executor(media_output: seams)
    chat = FakeChat.new
    run(executor, task("oi", channel: { capabilities: %w[image_output] }), chat)

    expect(completed(executor)).not_to have_key(:output_parts)
  end
end
