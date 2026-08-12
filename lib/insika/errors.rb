# frozen_string_literal: true

module Insika
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

    # A provider/transport failure, wrapped by ProviderErrorClassifier with an
  # ACTION classification (B9). The fields ride in the task's error record and
  # the :task_failed event so the client envelope can tell fatal from
  # retryable and quote the provider's own retry_after (A8). A bare
  # `ProviderError.new("boom")` has an empty classification and adds nothing
  # to the contract.
  class ProviderError < Error
    attr_reader :kind, :retryable, :retry_after

    def initialize(message = nil, kind: nil, retryable: nil, retry_after: nil)
      @kind = kind
      @retryable = retryable
      @retry_after = retry_after
      super(message)
    end

    # the additive envelope fields, compacted — nil retry_after stays absent.
    def classification
      { kind: kind, retryable: retryable, retry_after: retry_after }.compact
    end
  end

  # The hard budget refused the turn (WS2): the (tenant, agent) spend in the
  # window already met its cap BEFORE the turn ran. A typed, retryable failure —
  # the envelope reads `budget_exceeded` + `retry_after` (seconds until the
  # window rolls) — never a silent drop. `window` is :daily | :monthly.
  class BudgetExceeded < Error
    attr_reader :window, :retry_after

    def initialize(message = nil, window: nil, retry_after: nil)
      @window = window
      @retry_after = retry_after
      super(message || "budget exceeded (#{window})")
    end

    def classification
      { kind: :budget_exceeded, retryable: true, retry_after: retry_after }.compact
    end
  end

  # The circuit breaker refused the turn WITHOUT touching the provider (WS3):
  # the (tenant, provider/model) saw `after` failures within `within` seconds.
  # Typed + retryable — the envelope reads `circuit_open` + `retry_after`
  # (seconds until the cooldown lets a half-open trial through).
  class CircuitOpenError < Error
    attr_reader :ref, :retry_after

    def initialize(message = nil, ref: nil, retry_after: nil)
      @ref = ref
      @retry_after = retry_after
      super(message || "circuit open for #{ref}")
    end

    def classification
      { kind: :circuit_open, retryable: true, retry_after: retry_after }.compact
    end
  end
  class StoreError     < Error; end  # persistence backend failed -> task :failed
  class CancelledError < Error; end  # cooperative cancellation -> task :cancelled

  # Stage timeout overflow. Inside the Insika namespace this constant
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

  # Subagent graph integrity. Raised at DEFINITION-time
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

  # Workflow I/O contract violation. A workflow may declare an
  # `input_schema` / `output_schema`; a value that does not conform is rejected.
  # INPUT is validated SYNCHRONOUSLY (TriggerWorkflow) so it is a ValidationError
  # -> HTTP 422, no run created. OUTPUT is validated inside the fiber after the
  # workflow returns -> task :failed at the :workflow_schema stage. `errors` is the
  # per-field detail (dry-schema-compatible `#errors.to_h`); `phase` is :input|:output.
  class WorkflowSchemaError < ValidationError
    attr_reader :phase, :errors

    def initialize(message = nil, phase: nil, errors: {})
      @phase = phase
      @errors = errors || {}
      detail = @errors.map { |field, msgs| "#{field}: #{Array(msgs).join(', ')}" }.join("; ")
      base = message || "workflow #{phase} failed schema validation"
      super(detail.empty? ? base : "#{base} (#{detail})")
    end
  end

  # A channel could not hand a reply to its recipient. NOT a turn
  # failure: the turn already completed and its answer is durable in the session —
  # what failed is the delivery, which lives in the OutboxStore with its own status
  # and its own bounded retry. Raised by a channel's `deliver` so the dispatcher can
  # tell "the recipient refused" from "the engine has a bug".
  class DeliveryError < Error; end

  # Strict configuration violation (— OpenClaw's config discipline:
  # "recusa boot com chave desconhecida, no silent config compat"). Raised by
  # EnvSchema.enforce! at boot ONLY when strictness is on (INSIKA_CONFIG_STRICT) —
  # by default a bad key WARNS and the engine still boots (last-known-good: a rotated
  # env or a typo never takes the whole service down). `findings` carries the
  # per-key detail (EnvSchema::Finding) so the operator can fix the config.
  class ConfigError < Error
    attr_reader :findings

    def initialize(message = nil, findings: [])
      @findings = findings || []
      detail = @findings.map { |f| f.respond_to?(:message) ? f.message : f.to_s }.join("; ")
      base = message || "strict config check failed"
      super(detail.empty? ? base : "#{base}: #{detail}")
    end
  end
end
