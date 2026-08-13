# frozen_string_literal: true

module Insika
  # The reliability policy for the turn's provider interaction (WS3): retries
  # with exponential backoff, mid-turn ROTATION across the fallback chain, and
  # the circuit breaker — all as DATA on `AgentProfile#reliability`, never a
  # parallel code path. The failure classification is B9's
  # (ProviderErrorClassifier): ONLY :retryable / :rate_limited_* ever retry or
  # rotate; a :fatal is re-raised immediately (a poisoned credential must not
  # hammer N models).
  #
  # Each ATTEMPT is a fresh chat built by the caller (the coordinator yields the
  # selection): a failed `ask` leaves its user message in the chat, so re-asking
  # the same chat would double the input. The customer-visible answer comes only
  # from the attempt that returns; the fragments of failed attempts ride
  # :intermediate (operator-side) and die with the turn.
  #
  # The breaker is per (tenant, provider/model): a node whose circuit is open is
  # skipped (fail-fast with CircuitOpenError when the PRIMARY is open — the turn
  # dies in ms, no provider call); a node that tripped mid-turn moves on.
  class Reliability
    DEFAULT_TIMEOUT = 30 # seconds per attempt (reliability["timeout"])

    # circuit_store: CircuitState (the breaker's durable cells).
    # event_stream:  where the reliability events go (:provider_fallback, ...).
    # sleeper:       ->(seconds) — the backoff wait; injectable for specs.
    def initialize(circuit_store:, event_stream:, sleeper: nil)
      @circuit_store = circuit_store
      @event_stream = event_stream
      @sleeper = sleeper || method(:backoff_wait)
    end

    # policy:   the profile's reliability data (string keys) — the caller skips
    #           this coordinator entirely when nil (parity).
    # tenant:   the command tenant (breaker scoping; nil = platform).
    # agent:    the agent id (event attribution — WS6 alerts read it).
    # selection: the resolved primary ModelSelection.
    # chain:    [{ model:, provider: }] fallback candidates (profile's first,
    #           then the platform's resolved fallbacks).
    # attempt:  ->(selection, attempt_index) { response } — build the chat for
    #           that selection and ask. May RAISE a provider-family error.
    #
    # -> the successful response. Raises CircuitOpenError (primary open),
    # or the last retryable error when every node exhausted its retries.
    # NOTHING about a run is stored on `self`: one Reliability instance serves
    # every concurrent turn, and `ask` is a suspension point — an ivar written
    # here would be read back after another fiber's turn overwrote it, and the
    # WS6 alert would name the wrong agent (and, through it, the wrong tenant).
    # The run's identity rides the stack.
    def call(policy:, tenant:, agent: nil, selection:, chain:, &attempt)
      nodes = ([selection] + Array(chain)).map { |node| { selection: node, tries: 0 } }
      retries = [policy["retries"].to_i, 0].max
      breaker = breaker_config(policy)
      # The per-attempt ceiling. A policy WITHOUT a timeout is DEFAULT_TIMEOUT —
      # nothing config overrides here (the old [.., 1].max silently made every
      # unset profile die in ~1s, WS3).
      configured_timeout = policy["timeout"].to_i
      timeout = configured_timeout.positive? ? configured_timeout : DEFAULT_TIMEOUT
      # declaraed HERE (not inside a block) so the post-loop `raise` sees the
      # method-local binding — a first assignment inside a block would not leak.
      last_error = nil

      # Fail-fast BEFORE any provider call: the PRIMARY's circuit open means
      # this provider family is known-dead — the turn dies in ms.
      if breaker && breaker_open?(tenant, selection, breaker)
        raise circuit_open(tenant, selection, breaker)
      end
      nodes.each do |node|
        selection = node[:selection]
        next if breaker && breaker_open?(tenant, selection, breaker)

        attempts = retries + 1
        attempts.times do |index|
          node[:tries] += 1
          begin
            response = with_attempt_timeout(timeout) { yield selection, node[:tries] }
            @circuit_store.record_success(tenant: tenant, ref: ref_of(selection)) if breaker
            return response
          rescue StandardError => e
            last_error = e
            # A :fatal provider error — or ANYTHING that is not a provider
            # failure at all (a bug, a domain error, a guardrail raise) — is
            # never retried, never rotated (B9's structural rule). Only
            # retryable/rate-limited (and the per-attempt timeout we raised)
            # spend the retry budget. The B9 classifier is class-name based, so
            # OUR TimeoutError reads as :fatal — the retryable_failure? check
            # (which owns the reliability-stage timeout) must decide FIRST, or
            # the :fatal guard would swallow it (WS3: a timeout never retried,
            # never rotated).
            retryable = retryable_failure?(e)
            raise unless retryable
            raise if kind_of(e) == :fatal && !e.is_a?(Insika::TimeoutError)

            record_failure(tenant, selection, breaker, e, agent)
            # the last attempt of the last node re-raises; otherwise back off
            # and give the next attempt/node a turn.
            if index < attempts - 1 || node != nodes.last
              @sleeper.call(backoff_seconds(policy, index))
            end
          end
        end
      end
      raise last_error if last_error

      raise Insika::Error, "reliability loop exhausted without a result"
    end

    private

    def breaker_config(policy)
      b = policy["circuit_breaker"]
      return nil unless b.is_a?(Hash) && b["after"].to_i.positive?

      { after: b["after"].to_i, within: b["within"].to_i, cooldown: b["cooldown"].to_i }
    end

    # The breaker cell reads need the POLICY's numbers; they ride as args. Only
    # :open FAIL-FASTS; :half_open (cooldown elapsed) is the TRIAL — allowed.
    def breaker_open?(tenant, selection, breaker)
      @circuit_store.state(tenant: tenant, ref: ref_of(selection),
                           after: breaker[:after], within: breaker[:within],
                           cooldown: breaker[:cooldown]) == :open
    end

    def circuit_open(tenant, selection, breaker)
      Insika::CircuitOpenError.new(
        "circuit open for #{ref_of(selection)}",
        ref: ref_of(selection),
        retry_after: @circuit_store.retry_after(tenant: tenant, ref: ref_of(selection),
                                                cooldown: breaker[:cooldown])
      )
    end

    def record_failure(tenant, selection, breaker, error, agent)
      return unless breaker

      tripped = @circuit_store.record_failure(
        tenant: tenant, ref: ref_of(selection),
        after: breaker[:after], within: breaker[:within]
      )
      emit(:provider_failure,
           { agent: agent, ref: ref_of(selection), error: error.class.name, kind: kind_of(error) })
      # the failure that TRIPPED the circuit is itself an alert (WS6).
      emit(:breaker_open, { agent: agent, ref: ref_of(selection), tenant: tenant }) if tripped == :open
    end

    def kind_of(error) = ProviderErrorClassifier.classify(error).kind

    # A provider-family error OR the per-attempt timeout: both are transient
    # transport-class failures that spend the retry budget.
    def retryable_failure?(error)
      ProviderErrorClassifier.provider_error?(error) ||
        (error.is_a?(Insika::TimeoutError) && error.stage.to_s == "reliability")
    end

    def with_attempt_timeout(timeout, &blk)
      return yield unless Async::Task.current?
      Async::Task.current.with_timeout(timeout) { yield }
    rescue Async::TimeoutError
      # a per-attempt timeout is a TRANSPORT-class failure: counted, retried.
      raise Insika::TimeoutError.new("provider attempt exceeded #{timeout}s", stage: :reliability)
    end

    # The breaker cell id: "provider/model" for the ref'd node — a ModelSelection
    # (primary) or a { model:, provider: } hash (fallback node).
    def ref_of(selection)
      model = selection.respond_to?(:model) ? selection.model.to_s : selection[:model].to_s
      provider = selection.respond_to?(:provider) ? selection.provider : selection[:provider]
      provider ? "#{provider}/#{model}" : model
    end

    def backoff_seconds(policy, index)
      case policy["backoff"].to_s
      when "exponential" then 2**index
      else index + 1
      end
    end

    def backoff_wait(seconds)
      Async::Task.current? ? Async::Task.current.sleep(seconds) : Kernel.sleep(seconds)
    end

    def emit(type, data)
      @event_stream.emit(Insika::Event.new(
                           type: type, data: data, meta: { at: Time.now.utc.iso8601 }
                         ))
    end
  end
end