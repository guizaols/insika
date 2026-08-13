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
  let(:event_stream) { SpyEventStream.new }
  let(:selection) { Insika::ModelSelection.new(model: "deepseek-v4-flash", provider: :deepseek, source: :agent) }
  let(:policy) do
    { "retries" => 1, "backoff" => "exponential",
      "fallback" => ["openai/gpt-4o-mini"],
      "circuit_breaker" => { "after" => 3, "within" => 60, "cooldown" => 300 },
      "timeout" => 30 }
  end
  # Chain nodes yielded to the attempt block, in order.
  let(:chain) { [{ model: "gpt-4o-mini", provider: :openai }] }

  def run(attempts, policy: self.policy, selection: self.selection, chain: self.chain, agent: nil)
    reliability.call(policy: policy, tenant: nil, agent: agent, selection: selection,
                     chain: chain, &attempts)
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

  # The B9 classifier (class-name based) reads our TimeoutError as :fatal. The
  # coordinator must NOT let that guard swallow the per-attempt timeout — it is
  # explicitly retryable and must rotate to the fallback (WS3).
  it "a per-attempt timeout is retried and rotates to the fallback (not fatal)" do
    seen = []
    attempts = lambda do |sel, _n|
      seen << (sel.respond_to?(:model) ? sel.model : sel[:model])
      raise Insika::TimeoutError.new("provider attempt exceeded 30s", stage: :reliability)
    end
    expect { run(attempts) }.to raise_error(Insika::TimeoutError)
    # retries: 1 = 2 primary shots, then the fallback also exhausts its 2 shots
    expect(seen).to eq(%w[deepseek-v4-flash deepseek-v4-flash gpt-4o-mini gpt-4o-mini])
  end

  # The old [policy["timeout"].to_i, 1].max made an UNSET timeout 1s and the
  # classification bug turned that into an immediate fatal — a profile with
  # reliability but no explicit timeout killed real turns in ~1s. With
  # DEFAULT_TIMEOUT (30s) a slow-but-ok attempt survives a 1.5s window.
  it "a policy WITHOUT a timeout uses DEFAULT_TIMEOUT, not 1s" do
    require "async"
    no_timeout = policy.merge("timeout" => nil)
    task = Async do
      reliability.call(policy: no_timeout, tenant: nil, selection: selection, chain: []) do |_sel, _n|
        Async::Task.current.sleep(1.5)
        "slow but ok"
      end
    end
    expect(task.wait).to eq("slow but ok")
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

  it "the failure that TRIPS the breaker emits :breaker_open with the agent (WS6)" do
    trip_policy = policy.merge("circuit_breaker" => { "after" => 2, "within" => 60, "cooldown" => 300 })
    run(->(_s, _n) { raise RubyLLM::ServerError.new("down") }, policy: trip_policy, agent: "bia")
  rescue RubyLLM::ServerError
    nil
  ensure
    opened = event_stream.events.find { |e| e.type == :breaker_open }
    expect(opened).not_to be_nil
    expect(opened.data).to include(ref: "deepseek/deepseek-v4-flash", agent: "bia")
    # both nodes trip here (primary and then the fallback) — each cell opens once
    expect(event_stream.events.count { |e| e.type == :breaker_open }).to eq(2)
  end

  # ONE instance serves every concurrent turn and `ask` is a suspension point:
  # a run that parked its agent on the instance had it overwritten by whoever
  # ran next, so the alert named the wrong agent — and, through it, somebody
  # else's tenant. The run's identity must ride the stack.
  it "attributes each failure to ITS OWN agent when two turns interleave" do
    require "async"
    # `after` high enough that nothing trips: this is about attribution only.
    quiet = policy.merge("circuit_breaker" => { "after" => 100, "within" => 60, "cooldown" => 300 })
    slow = lambda do |_sel, _n|
      Async::Task.current.sleep(0.005) # the provider wait: the other turn runs here
      raise RubyLLM::ServerError.new("down")
    end
    fast = ->(_sel, _n) { raise RubyLLM::ServerError.new("down") }

    Sync do
      [Async { run(slow, policy: quiet, agent: "alfa") rescue nil },
       Async { run(fast, policy: quiet, agent: "beta") rescue nil }].each(&:wait)
    end

    agents = event_stream.events.select { |e| e.type == :provider_failure }.map { |e| e.data[:agent] }
    # 2 nodes x (retries: 1 + 1) attempts = 4 failures per run, each its own
    expect(agents.count("alfa")).to eq(4)
    expect(agents.count("beta")).to eq(4)
  end
end