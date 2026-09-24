# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/insika/telemetry/ruby_llm_instrumenter"

RSpec.describe Insika::Telemetry::RubyLLMInstrumenter do
  let(:events) { [] }
  let(:emit) { ->(type, data) { events << [type, data] } }
  let(:instrumenter) { described_class.new(emit: emit, operation: "chat", model: "deepseek-chat") }

  it "preserves the return value and records request duration using a monotonic clock" do
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(1.0, 1.025)
    result = Object.new
    expect(instrumenter.instrument("request.ruby_llm", provider: "deepseek") { result }).to equal(result)
    expect(events.last.first).to eq(:llm_request)
    expect(events.last.last).to include("operation" => "chat", "model" => "deepseek-chat", "status" => "succeeded")
    expect(events.last.last["duration_ms"]).to be_within(0.001).of(25)
  end

  it "preserves the same model exception and never records its message" do
    error = RuntimeError.new("private provider detail")
    expect { instrumenter.instrument("request.ruby_llm", {}) { raise error } }
      .to raise_error { |raised| expect(raised).to equal(error) }
    expect(events.last.last).to include("status" => "failed", "exception_class" => "RuntimeError")
    expect(JSON.generate(events)).not_to include("private provider detail")
  end

  it "preserves both outcomes when recording fails" do
    broken = described_class.new(emit: ->(*) { raise "recorder down" })
    expect(broken.instrument("request.ruby_llm", {}) { :result }).to eq(:result)
    error = RuntimeError.new("private provider detail")
    expect { broken.instrument("request.ruby_llm", {}) { raise error } }
      .to raise_error { |raised| expect(raised).to equal(error) }
  end

  it "keeps unknown usage unknown and discards fields outside the scalar allowlist" do
    instrumenter.instrument("usage.ruby_llm", operation: :chat, provider: "deepseek", model: "deepseek-chat",
      status: :failed, tokens: nil, cost: nil, messages: ["secret"], arguments: "secret", exception: "secret")
    expect(events).to eq([[:llm_usage, {
      "operation" => "chat", "provider" => "deepseek", "model" => "deepseek-chat", "status" => "failed",
      "request_id" => nil, "input_tokens" => nil, "output_tokens" => nil, "cache_read_tokens" => nil,
      "cache_write_tokens" => nil, "thinking_tokens" => nil, "cost" => nil
    }]])
  end

  it "normalizes only supported token counts and the reported total cost" do
    tokens = RubyLLM::Tokens.new(input: 10, output: 3, cache_read: 2, cache_write: 1, thinking: 1)
    cost = RubyLLM::Cost.new(tokens: RubyLLM::Tokens.new(reported_cost: 0.25))
    instrumenter.instrument("usage.ruby_llm", tokens: tokens, cost: cost)
    expect(events.last.last).to include("input_tokens" => 10, "output_tokens" => 3, "cache_read_tokens" => 2,
      "cache_write_tokens" => 1, "thinking_tokens" => 1, "cost" => 0.25)
    expect(events.last.last).not_to have_key("duration_ms")
  end

  it "retains the host instrumenter's block and notification behavior" do
    calls = []
    host = Object.new
    host.define_singleton_method(:instrument) do |name, payload, &block|
      calls << [name, payload]
      block&.call(payload)
    end
    bridge = described_class.new(emit: emit, delegate: host)
    payload = { private: "host-owned" }
    expect(bridge.instrument("chat.ruby_llm", payload) { |p| p[:private] }).to eq("host-owned")
    bridge.instrument("usage.ruby_llm", {})
    expect(calls).to eq([["chat.ruby_llm", payload], ["usage.ruby_llm", {}]])
  end

  it "does not swallow a model exception when the host suppresses it or replaces it" do
    error = RuntimeError.new("private provider detail")
    [nil, RuntimeError.new("host failure")].each do |replacement|
      host = Object.new
      host.define_singleton_method(:instrument) do |*, &block|
        begin
          block.call
        rescue StandardError
          raise replacement if replacement
        end
      end
      bridge = described_class.new(emit: emit, delegate: host)
      expect { bridge.instrument("request.ruby_llm", {}) { raise error } }
        .to raise_error { |raised| expect(raised).to equal(error) }
    end
  end

  it "runs the model once when host instrumentation fails before or after yielding" do
    [false, true].each do |yields|
      host = Object.new
      host.define_singleton_method(:instrument) do |*, &block|
        block.call if yields
        raise "host failure"
      end
      count = 0
      bridge = described_class.new(emit: emit, delegate: host)
      expect(bridge.instrument("request.ruby_llm", {}) { count += 1; :done }).to eq(:done)
      expect(count).to eq(1)
    end
  end
end
