# frozen_string_literal: true

require "spec_helper"

# Unit tests of the WS3 coordinator: the retry/backoff/fallback/breaker loop.
# The attempts are plain blocks; the provider errors are REAL RubyLLM classes
# (the B9 classifier is class-name based).
RSpec.describe Insika::Reliability do
  subject(:reliability) do
    described_class.new(circuit_store: circuit_store, event_stream: event_stream,
                        sleeper: ->(_s) { @slept ||= 0; @slept += 1 })
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:circuit_store) { Insika::CircuitState.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  let(:selection) { Insika::ModelSelection.new(model: "deepseek-v4-flash", provider: :deepseek, source: :agent) }
  let(:policy) do
    { "retries" => 1, "backoff" => "exponential",
      "fallback" => ["openai/gpt-4o-mini"],
      "circuit_breaker" => { "after" => 3, "within" => 60, "cooldown" => 300 },
      "timeout" => 30 }
  end
  # Chain nodes yielded to the attempt block, in order.
  let(:chain) { [{ model: "gpt-4o-mini", provider: :openai }] }

  def run(attempts, policy: self.policy, selection: self.selection, chain: self.chain)
    reliability.call(policy: policy, tenant: nil, selection: selection, chain: chain, &attempts)
  end

  def raise_retryable(klass = RubyLLM::ServerError)
    ->(_sel, _n) { raise klass.new("down") }
  end

  it "a retryable failure retries (retries: 1 -> up to 2 attempts), then succeeds" do
    calls = 0
    result = run(->(_s, _n) { calls += 1; raise RubyLLM::ServerError.new("down") if calls < 2; "ok" })
    expect(result).to eq("ok")
    expect(calls).to eq(2)
  end

  it "exhausted retries re-raise the LAST retryable error (never swallowed)" do
    expect { run(raise_retryable) }.to raise_error(RubyLLM::ServerError, "down")
  end

  it "a :fatal provider error is NEVER retried nor rotated (B9's structural rule)" do
    calls = 0
    attempts = ->(_s, _n) { calls += 1; raise RubyLLM::UnauthorizedError.new("bad key") }
    expect { run(attempts) }.to raise_error(RubyLLM::UnauthorizedError)
    expect(calls).to eq(1) # no retry, no fallback
  end

  it "a NON-provider error (a bug) is never retried either" do
    calls = 0
    attempts = ->(_s, _n) { calls += 1; raise "bug" }
    expect { run(attempts) }.to raise_error(RuntimeError, "bug")
    expect(calls).to eq(1)
  end

  it "after the primary's retries, the FALLBACK model is tried (mid-turn rotation)" do
    seen = []
    attempts = lambda do |sel, _n|
      seen << (sel.respond_to?(:model) ? sel.model : sel[:model])
      raise RubyLLM::ServerError.new("down") if sel.respond_to?(:model) # the primary always fails

      "fallback answered"
    end
    expect(run(attempts)).to eq("fallback answered")
    expect(seen).to eq(%w[deepseek-v4-flash deepseek-v4-flash gpt-4o-mini]) # retries: 1 = 2 primary shots, then the fallback
  end

  it "a successful attempt CLOSES the circuit (a half-open trial closes it)" do
    # trip the primary's circuit with an INSTANT cooldown -> the next check is
    # a :half_open trial, which must be allowed and, on success, close.
    trial_policy = policy.merge("circuit_breaker" => { "after" => 1, "within" => 60, "cooldown" => 0 })
    circuit_store.record_failure(tenant: nil, ref: "deepseek/deepseek-v4-flash", after: 1, within: 60)

    calls = 0
    run(->(_s, _n) { calls += 1; "ok" }, policy: trial_policy)
    expect(calls).to eq(1) # the trial went through
    expect(circuit_store.state(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                               after: 1, within: 60, cooldown: 0)).to eq(:closed)
  end

  it "fail-fast: the PRIMARY's circuit OPEN -> CircuitOpenError with retry_after, no provider call" do
    3.times { circuit_store.record_failure(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                                           after: 3, within: 60) }
    calls = 0
    error = nil
    begin
      run(->(_s, _n) { calls += 1; "ok" })
    rescue Insika::CircuitOpenError => e
      error = e
    end

    expect(error).not_to be_nil
    expect(error.retry_after).to eq(300) # full cooldown owed
    expect(error.classification).to eq(kind: :circuit_open, retryable: true, retry_after: 300)
    expect(calls).to eq(0) # the provider was never touched
  end

  it "an OPEN FALLBACK node is skipped (the next node still gets its turn)" do
    3.times { circuit_store.record_failure(tenant: nil, ref: "openai/gpt-4o-mini", after: 3, within: 60) }
    seen = []
    attempts = lambda do |sel, _n|
      seen << (sel.respond_to?(:model) ? sel.model : sel[:model])
      raise RubyLLM::ServerError.new("down")
    end
    expect { run(attempts) }.to raise_error(RubyLLM::ServerError)
    expect(seen).to eq(%w[deepseek-v4-flash deepseek-v4-flash]) # the open fallback was never attempted
  end

  it "without a circuit_breaker the policy is plain retries+fallback (no breaker reads)" do
    plain = policy.merge("circuit_breaker" => nil)
    calls = 0
    result = run(->(_s, _n) { calls += 1; calls == 2 ? "ok" : raise(RubyLLM::ServerError.new("x")) },
                 policy: plain)
    expect(result).to eq("ok")
  end
end