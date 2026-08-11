# frozen_string_literal: true

# Honest stubs for stages D/E (interfaces from docs 04/05), minimal and
# deterministic behavior. They live in spec/support on purpose: the real components
# arrive in tasks 14-18; the production wiring closes in.

# Poor mirror of the Context Builder. #call(request) -> ContextPackage with system
# (from profile.base_prompt) and history in precedence: checkpoint.messages ->
# explicit history (vars["history"], the convention the Session provider uses) ->
# session messages -> [].
ContextPackage = Struct.new(:system, :history, :tool_context)

class FakeContextBuilder
  def call(request)
    history =
      request.checkpoint&.messages ||
      request.vars&.[]("history") ||
      request.session&.messages ||
      []
    ContextPackage.new(request.profile.base_prompt.to_s, history, nil)
  end
end

# Raises ContextError (single-capture test of stage 2).
class RaisingContextBuilder
  def call(_request) = raise Insika::ContextError.new("builder falhou", provider: :fake)
end

# Resolution-like. allowed_tools = injected instances; allowed_skills = names.
# requires_approval mirrors the real contract (the Resolution always has it).
Resolution = Struct.new(:allowed_tools, :allowed_skills, :requires_approval)

class NullPolicyEngine
  def initialize(allowed_tools: [])
    @allowed_tools = allowed_tools
  end

  def decide(request)
    Resolution.new(@allowed_tools, Array(request.candidate_skills).map(&:name), [])
  end
end

# Denies everything at stage 3 (RubyLLM is never touched).
class DenyAllPolicyEngine
  def decide(_request)
    raise Insika::PolicyDenied.new(policy: "deny_all", reason: "tudo negado no teste")
  end
end

# Executes the terminal block (passthrough).
class PassthroughMiddleware
  def call(state)
    yield state
  end
end

# Short-circuits: sets halt_reason and does NOT call the block.
class HaltingMiddleware
  def call(state)
    state.halt_reason = "rate limit"
    nil
  end
end

# around(pair, subject) { |s| yield s }, recording the order of the pairs. The
# run_before/run_after halves (:tool pair) are passthrough without recording.
class NullHooks
  attr_reader :pairs

  def initialize = (@pairs = [])

  def around(pair, subject)
    @pairs << pair
    yield subject
  end

  def run_before(_pair, subject) = subject
  def run_after(_pair, result) = result
end

# Synchronous event stream for order assertions without fiber choreography:
# emit just accumulates (the turn's fiber completes during spawn+wait).
class SpyEventStream
  attr_reader :events

  def initialize = (@events = [])
  def emit(event) = @events << event
  def types = @events.map(&:type)
end

# Stream double of Rack 3's STREAMING body (Protocol::HTTP::Body::Stream):
# collects the written frames and marks the close. `raise_on_write` simulates the
# closed socket (client disconnected). Used to drive SSEBody#call(stream) in the
# specs without booting an HTTP server.
class SSEStreamDouble
  attr_reader :chunks

  def initialize(raise_on_write: false)
    @chunks = []
    @raise_on_write = raise_on_write
    @closed = false
  end

  def write(chunk)
    raise "socket fechado" if @raise_on_write

    @chunks << chunk
  end

  def flush = nil
  def close = (@closed = true)
  def closed? = @closed
end

# Fake registry with the side_effect?(name) predicate (seam from).
class FakeToolRegistry
  def initialize(side_effect_names: [])
    @side_effect_names = Array(side_effect_names).map(&:to_s)
  end

  def side_effect?(name)
    @side_effect_names.include?(name.to_s)
  end

  def entries = [] # the Executor reads tool_registry.entries in the policy_request
end
