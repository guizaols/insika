# frozen_string_literal: true

require "spec_helper"

# The RubyLLM BOUNDARY contract. Every other spec drives a chat DOUBLE
# (spec/support/fake_chat.rb and friends), so a double that answers a method the
# gem does not have makes the suite green while production silently drops the
# call. That has happened twice:
#
#   · `base_prompt` was in the fake ContextBuilder's system and in no provider —
#     an agent whose identity was inline had no identity (fixed in #124);
#   · `with_max_output_tokens` was in the model_selection double and in no
#     version of the gem — `max_tokens` never reached a provider.
#
# This file is the guard: it asserts, against the REAL gem, that everything
# Insika sends across the boundary exists there, and that the shared double never
# offers more than the gem does. It SKIPS when the gem is absent (the suite also
# runs against spec/support/stubs/ruby_llm.rb, which has no Chat at all) — there
# is nothing to compare then.
RSpec.describe "RubyLLM boundary contract" do
  before { skip "real ruby_llm gem not installed" unless defined?(RubyLLM::Chat) }

  # What Insika actually sends to a chat, with the call site of each.
  CHAT_CALLS = {
    with_instructions: "ChatBuilder#apply_instructions",
    with_tools: "ChatBuilder#configure_chat",
    add_message: "ChatBuilder#seed_history",
    before_tool_call: "ChatBuilder#wire_callbacks",
    after_tool_result: "ChatBuilder#wire_callbacks",
    ask: "Executor#run_agent",
    messages: "Executor#recorded_turn_messages",
    model: "ChatBuilder#anthropic_provider?",
    with_temperature: "ModelSelection#apply_params",
    with_params: "ModelSelection#apply_payload_params (max_tokens, thinking toggle)",
    with_thinking: "ModelSelection#apply_effort"
  }.freeze

  # What Insika READS off a response/chunk. Both are RubyLLM::Message (Chunk
  # subclasses it), all duck-typed with respond_to? in the Executor — which is
  # exactly why a rename would be silent.
  MESSAGE_READS = %i[
    role content tool_calls tool_call_id
    input_tokens output_tokens cached_tokens cache_creation_tokens model_id thinking
  ].freeze

  it "RubyLLM::Chat answers every method Insika sends it" do
    surface = RubyLLM::Chat.public_instance_methods
    CHAT_CALLS.each do |method, call_site|
      expect(surface).to include(method), "#{call_site} sends ##{method}, which RubyLLM::Chat does not have"
    end
  end

  # RubyLLM.chat is a `**kwargs` delegator, so the real signature to check is the
  # Chat constructor it forwards to.
  it "RubyLLM.chat takes the keywords Executor#create_chat passes" do
    expect(RubyLLM).to respond_to(:chat)
    keywords = RubyLLM::Chat.instance_method(:initialize).parameters.select { |kind, _| kind == :key }.map(&:last)
    expect(keywords).to include(:model, :provider, :assume_model_exists)
  end

  # Item 30. Insika passes `concurrency:` to with_tools and nothing else — the cap
  # is ours (ToolAssembly#install_tool_gate), the mode selection is not exposed.
  # Everything below is a GEM fact our docs promise; if a version changes any of
  # them, the promise is wrong and this fails instead of production.
  describe "parallel tool calls (item 30)" do
    it "with_tools takes the concurrency: keyword ChatBuilder passes" do
      keywords = RubyLLM::Chat.instance_method(:with_tools).parameters.select { |k, _| k == :key }.map(&:last)
      expect(keywords).to include(:concurrency)
    end

    it ":fibers is an admissible mode (the only one Insika will ever send)" do
      expect(RubyLLM::ToolConcurrency.supported?(:fibers)).to be(true)
    end

    # ChatBuilder sends the tools AND the keyword in ONE call, and `with_tools`
    # re-applies `@concurrency` once per tool before the outer update — so the order
    # inside the gem decides whether our value survives. Asserted on a REAL Chat,
    # since that is the only thing that can go wrong here. Building one touches the
    # PROCESS-WIDE config singleton (see LLMConfigurator's gotcha), so the key is
    # restored; nothing here reaches the network.
    it "ChatBuilder's exact call lands on a real Chat's #concurrency" do
      previous = RubyLLM.config.openai_api_key
      RubyLLM.configure { |c| c.openai_api_key = "spec-only" }
      chat = RubyLLM.chat(model: "gpt-4o-mini", provider: :openai, assume_model_exists: true)

      chat.with_tools(RubyLLM::Tool.new, concurrency: :fibers)

      expect(chat.concurrency).to eq(:fibers)
    ensure
      RubyLLM.configure { |c| c.openai_api_key = previous }
    end

    # F1: before_tool_call -> tool.call -> after_tool_result run in the SAME child
    # fiber. This is what makes TurnState's fiber-storage correlation correct and a
    # single mutable slot wrong (P11a).
    it "one fiber per call, spanning the whole callback/call/result cycle" do
      fibers = {}
      RubyLLM::ToolConcurrency.run(:fibers, { "a" => "a", "b" => "b" }) do |id|
        seen = [Fiber.current.object_id]
        Async::Task.current.sleep(0.01) # a switch point, so the fibers really interleave
        fibers[id] = seen << Fiber.current.object_id
      end

      expect(fibers["a"].uniq.size).to eq(1)          # one fiber for the whole call
      expect(fibers["a"].first).not_to eq(fibers["b"].first) # and a different one per call
    end

    # F3 / D5: an exception in one call does NOT stop its siblings — every tool in
    # the batch runs, and the raise surfaces after collection. That is why
    # `max_tool_calls` stops being exact under concurrency (up to N-1 extra tools
    # execute), which docs/TOOLS.md states rather than pretending otherwise.
    it "a failing call does not stop its siblings; the raise comes after the batch" do
      ran = []
      expect do
        RubyLLM::ToolConcurrency.run(:fibers, { "a" => "a", "b" => "b", "c" => "c" }) do |id|
          ran << id
          raise "boom" if id == "a"

          "ok"
        end
      end.to raise_error("boom")

      expect(ran.sort).to eq(%w[a b c])
    end

    # F2 / D6: on_result fires in COMPLETION order, so the `role: tool` transcript
    # messages are appended as results arrive, not in call order. Providers key
    # results by tool_call_id so the wire stays valid — see the Session provider
    # spec for the eviction-unit grouping that has to tolerate it.
    it "results are delivered in completion order, not call order" do
      order = []
      RubyLLM::ToolConcurrency.run(:fibers, { "slow" => "slow", "fast" => "fast" },
                                   on_result: ->(tool_call, _v) { order << tool_call }) do |id|
        Async::Task.current.sleep(0.05) if id == "slow"
        id
      end

      expect(order).to eq(%w[fast slow])
    end

    # D7. The map assumed the turn timeout would CANCEL tool calls in flight,
    # because the gem nests `Async{}` under our task. It does not, and this is the
    # spec that says so: `with_timeout` raises in the fiber blocked on `.wait`, and
    # an Async task does not finish before its children do — so the turn timeout
    # surfaces only AFTER the in-flight calls return. Serial execution is prompt
    # (the tool runs in the turn's own fiber, and ToolEnvelope's ToolTimeout is a
    # distinct class precisely so the turn timeout is never swallowed); concurrent
    # execution can overrun `turn_timeout` by up to `tool_timeout`, which is what
    # bounds it. Written down in docs/TOOLS.md rather than pretended away.
    it "the turn timeout waits for in-flight tool calls instead of cancelling them" do
      finished = []
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect do
        Sync do |task|
          task.with_timeout(0.05) do
            RubyLLM::ToolConcurrency.run(:fibers, { "a" => "a" }) do |id|
              Async::Task.current.sleep(0.3) # stands in for a tool bounded by tool_timeout
              finished << id
            end
          end
        end
      end.to raise_error(Async::TimeoutError)

      expect(finished).to eq(["a"]) # ran to completion despite the 0.05s deadline
      # ...and the raise reached the caller only after it did.
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.3
    end
  end

  it "with_thinking takes effort: (the reasoning effort levels)" do
    keywords = RubyLLM::Chat.instance_method(:with_thinking).parameters.select { |k, _| k == :key }.map(&:last)
    expect(keywords).to include(:effort)
  end

  # §11 R1 rehydration: the seeded history must SURVIVE as tool calls/results, or
  # the model stops seeing the tools it already called.
  it "a seeded message keeps the tool_calls/tool_call_id ChatBuilder rehydrates" do
    call = RubyLLM::ToolCall.new(id: "call_1", name: "search", arguments: { "q" => "x" })
    assistant = RubyLLM::Message.new(role: :assistant, content: "", tool_calls: { "call_1" => call })
    result = RubyLLM::Message.new(role: :tool, content: "found", tool_call_id: "call_1")

    expect(assistant.tool_calls["call_1"].name).to eq("search")
    expect(result.tool_call_id).to eq("call_1")
  end

  it "RubyLLM::Message answers every field the Executor reads" do
    surface = RubyLLM::Message.public_instance_methods
    MESSAGE_READS.each { |field| expect(surface).to include(field) }
    expect(RubyLLM::Chunk.public_instance_methods).to include(:content, :thinking)
    expect(RubyLLM::Thinking.public_instance_methods).to include(:text) # emit_thinking reads chunk.thinking.text
  end

  # §11 R3 prompt caching: no double reaches this path (a fake chat has no model,
  # so anthropic_provider? is false and caching stays off) — assert the shape here.
  it "Anthropic's Content takes cache: true (the prompt-cache breakpoint)" do
    content = RubyLLM::Providers::Anthropic::Content.new("system text", cache: true)
    expect(content).to be_a(RubyLLM::Content::Raw)
  end

  # ModelSelection#apply_params is the one place that sends chat methods behind
  # `respond_to?`, so a method the gem does not have is skipped in SILENCE — no
  # exception, no log, the param simply never reaches the provider. A promiscuous
  # spy answers everything, which makes every branch fire; the assertion is then
  # against the real class. This is the shape that catches the next
  # `with_max_output_tokens`, and no hand-maintained list can go stale.
  describe "ModelSelection#apply_params (silent-skip guard)" do
    let(:spy) do
      Class.new do
        attr_reader :sent

        def initialize = (@sent = [])
        def respond_to_missing?(_name, _private = false) = true
        def method_missing(name, *_args, **_kwargs) = (@sent << name; self)
      end.new
    end

    def apply(params)
      Insika::ModelSelection.new(model: "m", provider: :deepseek, params: params).apply_params(spy)
      spy.sent.uniq
    end

    it "sends only methods RubyLLM::Chat has (toggle branch)" do
      sent = apply({ temperature: 0.2, max_tokens: 200, thinking: "off" })
      expect(sent).to include(:with_temperature, :with_params)
      expect(sent - RubyLLM::Chat.public_instance_methods).to be_empty
    end

    it "sends only methods RubyLLM::Chat has (effort branch)" do
      sent = apply({ max_tokens: 200, thinking: "high" })
      expect(sent).to include(:with_params, :with_thinking)
      expect(sent - RubyLLM::Chat.public_instance_methods).to be_empty
    end
  end

  # The anti-theater invariant. Everything the shared double exposes is either a
  # method of the real Chat or declared scaffolding here; a new method that is
  # neither fails this spec, and the fix is to check the gem before the double.
  describe "spec/support/fake_chat.rb" do
    SCAFFOLDING = %i[
      asked instructions model=
      script script= final_content final_content=
      fire_tool_call fire_tool_result emit_chunk emit_thinking
    ].freeze

    it "doubles only methods RubyLLM::Chat really has" do
      doubled = FakeChat.public_instance_methods(false) - SCAFFOLDING
      expect(doubled - RubyLLM::Chat.public_instance_methods).to be_empty
    end

    it "its response/chunk structs expose only RubyLLM::Message fields" do
      message = RubyLLM::Message.public_instance_methods
      expect(FakeChat::Response.members - message).to be_empty
      expect(FakeChat::ThinkingChunk.members - message).to be_empty
      expect(FakeChat::Thought.members - RubyLLM::Thinking.public_instance_methods).to be_empty
    end
  end
end
