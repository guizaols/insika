# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Insika native compaction" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:settings) { Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend)) }
  let(:context) do
    RubyLLM.context do |config|
      config.openai_api_key = "spec-only"
      config.deepseek_api_key = "spec-only"
    end
  end
  let(:chat) { context.chat(model: "gpt-4o-mini", provider: :openai) }
  let(:profile) { Insika::AgentProfile.build(id: "a", model: "gpt-4o-mini", provider: "openai") }
  let(:task) { Struct.new(:id, :session_id).new("t", "s") }
  let(:builder) { Insika::ChatBuilder.allocate }
  let(:executor) do
    Insika::Executor.allocate.tap do |executor|
      executor.instance_variable_set(:@settings_store, settings)
      executor.instance_variable_set(:@session_store, sessions)
      executor.instance_variable_set(:@chat_builder, builder)
      allow(executor).to receive(:emit)
    end
  end
  let(:raw) do
    { "object" => "response.compaction",
      "output" => [{ "type" => "compaction", "encrypted_content" => "opaque-state" }] }
  end

  before do
    settings.update("compaction" => { "enabled" => true, "mode" => "native", "keep_last" => 2, "compact_after" => 3 })
    sessions.create(id: "s")
    6.times { |i| sessions.append_messages("s", { "role" => i.even? ? "user" : "assistant", "content" => "message #{i}" }) }
    allow_any_instance_of(RubyLLM::Providers::OpenAI).to receive(:compact) do |_, messages, **|
      expect(messages.map(&:content)).to eq(["message 0", "message 1", "message 2", "message 3"])
      RubyLLM::Message.new(role: :assistant, content: "", raw_content: raw, model: "gpt-4o-mini")
    end
  end

  def compact
    executor.send(:finalize_compaction, task, profile, chat)
  end

  def history(checkpoint: nil)
    request = Insika::ContextRequest.new(profile: profile, message: "next", session: sessions.find("s"),
      checkpoint: checkpoint, tenant: nil, vars: {})
    Insika::Context::Providers::Session.new(session_store: sessions).call(request).map(&:content)
  end

  it "persists native state separately and reuses it after a JSON checkpoint reload" do
    compact
    saved = sessions.find("s")
    expect(saved.messages.size).to eq(6)
    expect(saved.compaction).to include("upto" => 4, "runs" => 1)
    expect(saved.compaction).not_to have_key("summary")
    expect(saved.compaction.fetch("native").fetch("message").fetch("raw_content")).to eq(raw)

    checkpoint = Struct.new(:messages).new(JSON.parse(JSON.generate(history)))
    builder.seed_history(chat, history(checkpoint: checkpoint))
    expect(chat.messages.map(&:content)).to eq(["", "message 4", "message 5"])
    expect(chat.messages.first.raw_content).to eq(raw)
  end

  it "restores the original prefix on a different model or provider" do
    compact
    [context.chat(model: "gpt-4o", provider: :openai),
     context.chat(model: "deepseek-v4-flash", provider: :deepseek)].each do |fallback|
      builder.seed_history(fallback, history)
      expect(fallback.messages.map(&:content)).to eq(6.times.map { |i| "message #{i}" })
      expect(fallback.messages.map(&:raw_content)).to all(be_nil)
    end
  end

  it "does not replay native state with a different configured protocol" do
    compact
    context.config.openai_protocol = :chat_completions
    fallback = context.chat(model: "gpt-4o-mini", provider: :openai)
    builder.seed_history(fallback, history)
    expect(fallback.messages.map(&:content)).to eq(6.times.map { |i| "message #{i}" })
    expect(fallback.messages.map(&:raw_content)).to all(be_nil)
  end

  it "does not replay native state after a per-chat protocol override" do
    compact
    chat.with_model("gpt-4o-mini", provider: :openai, protocol: :chat_completions)
    builder.seed_history(chat, history)
    expect(chat.messages.map(&:raw_content)).to all(be_nil)
    expect(chat.messages.map(&:content)).to eq(6.times.map { |i| "message #{i}" })
  end

  it "ignores malformed native responses without discarding history" do
    allow_any_instance_of(RubyLLM::Providers::OpenAI).to receive(:compact)
      .and_return(RubyLLM::Message.new(role: :assistant, content: "not compaction"))
    compact
    expect(sessions.find("s").compaction).to be_nil
    expect(sessions.find("s").messages.size).to eq(6)
  end

  it "does not advance the boundary for an empty compacted output" do
    allow_any_instance_of(RubyLLM::Providers::OpenAI).to receive(:compact)
      .and_return(RubyLLM::Message.new(role: :assistant, content: "",
        raw_content: { "object" => "response.compaction", "output" => [] }))
    compact
    expect(sessions.find("s").compaction).to be_nil
  end

  it "charges the fallback prefix to the context budget and evicts it atomically" do
    compact
    request = Insika::ContextRequest.new(profile: profile.with(limits: profile.limits.merge(context_budget: 20)),
      message: "next", session: sessions.find("s"), checkpoint: nil, tenant: nil, vars: {})
    package = Sync do
      Insika::ContextBuilder.new(providers: [Insika::Context::Providers::Session.new(session_store: sessions)],
        event_stream: SpyEventStream.new).call(request)
    end
    builder.seed_history(chat, package.history)
    expect(chat.messages.map(&:content)).to eq(["message 4", "message 5"])
    expect(package.budget[:used]).to be <= 20
  end

  it "records native token usage without exposing the compacted payload" do
    allow_any_instance_of(RubyLLM::Providers::OpenAI).to receive(:compact)
      .and_return(RubyLLM::Message.new(role: :assistant, content: "", raw_content: raw,
        model: "gpt-4o-mini", input_tokens: 10, output_tokens: 2, cache_read_tokens: 4))
    compact
    expect(executor).to have_received(:emit).with(:context_compacted,
      hash_including(usage: hash_including(input_tokens: 10, output_tokens: 2, cached_tokens: 4)), task: task)
  end

  it "does not require a utility model in native mode" do
    finding = Insika::Doctor.new(env: {}, settings_store: settings).send(:check_compaction).first
    expect(finding.severity).to eq(:ok)
  end

  it "preserves history contributed before the session provider" do
    compact
    chat.add_message(role: :user, content: "other provider history")
    builder.seed_history(chat, history)
    expect(chat.messages.map(&:content)).to eq(["other provider history"] + 6.times.map { |i| "message #{i}" })
    expect(chat.messages.map(&:raw_content)).to all(be_nil)
  end

  it "keeps the previous state when the endpoint fails" do
    compact
    before = sessions.find("s").compaction
    4.times { sessions.append_messages("s", { "role" => "user", "content" => "later" }) }
    allow_any_instance_of(RubyLLM::Providers::OpenAI).to receive(:compact).and_raise(RubyLLM::Error, "offline")
    compact
    expect(sessions.find("s").compaction).to eq(before)
  end

  it "does not invoke a summary model for an unsupported native provider" do
    unsupported = context.chat(model: "deepseek-v4-flash", provider: :deepseek)
    expect(Insika::Compaction::SummarizerFactory).not_to receive(:build)
    executor.send(:finalize_compaction, task, profile, unsupported)
    expect(sessions.find("s").compaction).to be_nil
  end
end
