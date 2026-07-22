# frozen_string_literal: true

module Harness
  # Single error taxonomy.
  # General rule: an error becomes an event, a task has an explicit terminal
  # state, a checkpoint is never corrupted.
  class Error < StandardError; end

  class ValidationError < Error; end  # Malformed Command -> HTTP 422, no Task created
  class NotFoundError   < Error; end  # nonexistent session/task/agent -> HTTP 404

  # Policy Engine denied -> :policy_denied event, task :failed
  class PolicyDenied < Error
    attr_reader :policy, :reason

    def initialize(message = nil, policy: nil, reason: nil)
      @policy = policy
      @reason = reason
      super(message || "policy #{policy} denied: #{reason}")
    end
  end

  # A required provider failed -> task :failed
  class ContextError < Error
    attr_reader :provider

    def initialize(message = nil, provider: nil)
      @provider = provider
      super(message || "provider #{provider} failed")
    end
  end

  class ProviderError  < Error; end  # RubyLLM exhausted retries -> task :failed
  class StoreError     < Error; end  # persistence backend failed -> task :failed
  class CancelledError < Error; end  # cooperative cancellation -> task :cancelled

  # Stage timeout overflow. Inside the Harness namespace this constant
  # shadows the stdlib ::Timeout::Error — reference it without :: in here
  # (the contract forbids stdlib Timeout.timeout anyway).
  class TimeoutError < Error
    attr_reader :stage

    def initialize(message = nil, stage: nil)
      @stage = stage
      super(message || "timeout at stage #{stage}")
    end
  end

  # Capability resolution failed -> task :failed at the
  # :capability stage. Root of the subtree; it does NOT get its own event —
  # it propagates through the existing :error/:task_failed events, same
  # discipline as the taxonomy. Never raised directly (only its subclasses).
  class CapabilityError < Error; end

  # 0 candidates left after availability + deny.
  class CapabilityUnavailable < CapabilityError
    attr_reader :capability

    def initialize(message = nil, capability: nil)
      @capability = capability
      super(message || "capability #{capability} has no available provider")
    end
  end

  # >=2 candidates tied at the top (same priority AND same plugin) -> a
  # configuration error, NEVER a silent choice. `candidates` carries enough
  # for the operator to break the tie in the manifest.
  class CapabilityAmbiguous < CapabilityError
    attr_reader :capability, :candidates

    def initialize(message = nil, capability: nil, candidates: [])
      @capability = capability
      @candidates = candidates
      super(message || "capability #{capability} ambiguous between #{candidates.inspect}")
    end
  end

  # Subagent graph integrity (RFC-0010 §4.4). Raised at DEFINITION-time
  # (CreateAgent/UpdateAgent/boot) by SubagentGraph.validate! — a subagents
  # allowlist that forms a cycle or exceeds the depth cap is a configuration
  # error, never a runtime surprise. A ValidationError so the authoring Command
  # fails cleanly (HTTP 422, no profile persisted).
  class SubagentError < ValidationError; end

  class SubagentCycleError < SubagentError
    attr_reader :cycle

    def initialize(message = nil, cycle: [])
      @cycle = cycle
      super(message || "subagent cycle detected: #{cycle.join(' -> ')}")
    end
  end

  class SubagentDepthExceeded < SubagentError
    attr_reader :depth, :cap

    def initialize(message = nil, depth: nil, cap: nil)
      @depth = depth
      @cap = cap
      super(message || "subagent depth #{depth} exceeds cap #{cap}")
    end
  end
end
