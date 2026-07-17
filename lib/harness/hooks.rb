# frozen_string_literal: true

module Harness
  # Hooks ALTER the input/output of the ONE stage they wrap: Middleware
  # modifies, Hooks alter, Events observe. They don't create their own flow nor skip
  # stages. Synchronous and without rescue — the error->state mapping belongs to the Executor.
  class Hooks
    PAIRS = %i[task prompt agent tool].freeze

    def initialize
      @before = Hash.new { |h, k| h[k] = [] }
      @after = Hash.new { |h, k| h[k] = [] }
    end

    # callables; multiple per pair. Registration order is significant.
    def register(pair, before: nil, after: nil)
      raise ArgumentError, "unknown hook pair: #{pair.inspect}" unless PAIRS.include?(pair)

      @before[pair] << before if before
      @after[pair] << after if after
      nil
    end

    # befores in registration order (may ALTER the subject by returning the new one),
    # yield(subject), afters in REVERSE order (may alter the result). With no
    # registrations -> degenerates into yield(subject) (no-op). A hook that doesn't alter
    # returns what it received; returning nil IS altering to nil (no special case).
    def around(pair, subject)
      run_after(pair, yield(run_before(pair, subject)))
    end

    # Public halves of around. Needed for the :tool pair, whose
    # stage "body" is RubyLLM's inner loop — there is no block
    # to wrap; the halves are called from the before_tool_call/
    # after_tool_result callbacks separately.
    def run_before(pair, subject)
      raise ArgumentError, "unknown hook pair: #{pair.inspect}" unless PAIRS.include?(pair)

      @before[pair].reduce(subject) { |subj, hook| hook.call(subj) }
    end

    def run_after(pair, result)
      raise ArgumentError, "unknown hook pair: #{pair.inspect}" unless PAIRS.include?(pair)

      @after[pair].reverse.reduce(result) { |res, hook| hook.call(res) }
    end
  end
end
