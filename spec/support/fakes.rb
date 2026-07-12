# frozen_string_literal: true

# Stubs honestos das etapas D/E (interfaces dos docs 04/05), comportamento
# mínimo e determinístico. Vivem em spec/support de propósito: os componentes
# reais chegam nas tasks 14-18; o wiring de produção fecha na task 26.

# Espelho pobre do Context Builder. #call(request) -> ContextPackage com system
# (do profile.base_prompt) e history na precedência: checkpoint.messages ->
# history explícito (vars["history"], a convenção que o Session provider usa) ->
# mensagens da sessão -> [].
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

# Levanta ContextError (teste de captura única do estágio 2).
class RaisingContextBuilder
  def call(_request) = raise Harness::ContextError.new("builder falhou", provider: :fake)
end

# Resolution-like (doc 05 §4). allowed_tools = instâncias injetadas;
# allowed_skills = nomes (paridade Fase 0 até a task 17).
Resolution = Struct.new(:allowed_tools, :allowed_skills)

class NullPolicyEngine
  def initialize(allowed_tools: [])
    @allowed_tools = allowed_tools
  end

  def decide(request)
    Resolution.new(@allowed_tools, Array(request.candidate_skills).map(&:name))
  end
end

# Nega tudo no estágio 3 (RubyLLM nunca é tocado).
class DenyAllPolicyEngine
  def decide(_request)
    raise Harness::PolicyDenied.new(policy: "deny_all", reason: "tudo negado no teste")
  end
end

# Executa o bloco terminal (passthrough).
class PassthroughMiddleware
  def call(state)
    yield state
  end
end

# Curto-circuita: seta halt_reason e NÃO chama o bloco (doc 05 §3).
class HaltingMiddleware
  def call(state)
    state.halt_reason = "rate limit"
    nil
  end
end

# around(pair, subject) { |s| yield s }, gravando a ordem dos pares. As
# metades run_before/run_after (par :tool) são passthrough sem gravar.
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

# Event stream síncrono para asserções de ordem sem coreografia de fibers:
# emit só acumula (o fiber do turno completa durante spawn+wait).
class SpyEventStream
  attr_reader :events

  def initialize = (@events = [])
  def emit(event) = @events << event
  def types = @events.map(&:type)
end

# Registry fake com o predicado side_effect?(name) (seam do doc 06).
class FakeToolRegistry
  def initialize(side_effect_names: [])
    @side_effect_names = Array(side_effect_names).map(&:to_s)
  end

  def side_effect?(name)
    @side_effect_names.include?(name.to_s)
  end
end
