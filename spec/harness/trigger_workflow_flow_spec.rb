# frozen_string_literal: true

require "spec_helper"
require "async"

# Integração do estágio 6 variante (workflow) — workflow fake PORO, colaboradores
# fake da suíte da task 12. Sem ruby_llm.
RSpec.describe "Executor: trigger_workflow (estágio 6 variante)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:workflow_registry) { Harness::WorkflowRegistry.new }
  let(:tool_registry) { Harness::ToolRegistry.new }
  # perfil com WorkflowAllowlist nas policies + workflow permitido
  let(:profile) do
    Harness::AgentProfile.build(id: "sales", model: "gpt",
                                policies: %w[tool_allowlist workflow_allowlist],
                                workflows_allow: %w[flow])
  end

  let(:policy_registry) do
    {
      "tool_allowlist" => Harness::Policy::Builtin::ToolAllowlist.new,
      "workflow_allowlist" => Harness::Policy::Builtin::WorkflowAllowlist.new
    }
  end

  def build_executor(allowed_tools: [])
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new,
      policy_engine: Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream),
      middleware: PassthroughMiddleware.new, hooks: Harness::Hooks.new,
      tool_registry: tool_registry, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: { "sales" => profile }, session_store: session_store,
      task_store: task_store, checkpoint_store: checkpoint_store,
      event_stream: event_stream, workflow_registry: workflow_registry
    )
  end

  # Tool PORO como INSTÂNCIA callable com #name (o workflow chama tool.call).
  def poro_tool(name, &body)
    obj = Object.new
    obj.define_singleton_method(:name) { name }
    obj.define_singleton_method(:call) { |args| body ? body.call(args) : "ran:#{name}" }
    obj
  end

  def make_task(input: { "q" => "x" }, id: "t")
    command = Harness::Command.build(:trigger_workflow, { workflow: "flow", agent: "sales", input: input })
    task_store.create(command: command.to_h, session_id: nil, id: id)
  end

  def run(executor, task)
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  it "invoca o workflow com input, context (ContextPackage) e tools (instâncias filtradas)" do
    seen = {}
    workflow_registry.register("flow", lambda { |input, context:, tools:|
      seen[:input] = input
      seen[:context] = context
      seen[:tools] = tools
      "resultado do workflow"
    })
    # policy permite a tool "t" (via ToolAllowlist, allow nil -> todas required)
    tool_registry.register("t", poro_tool("t"))
    executor = build_executor

    run(executor, make_task(input: { "q" => "x" }))

    expect(seen[:input]).to eq({ "q" => "x" })
    expect(seen[:context]).to be_a(ContextPackage)
    expect(seen[:tools].map { |t| t.__getobj__ }).to all(respond_to(:name)) # instâncias envelopadas
    stored = task_store.find("t")
    expect(stored.status).to eq(:completed)
    done = event_stream.events.find { |e| e.type == :done }
    expect(done.data[:content]).to eq("resultado do workflow")
  end

  it "tools filtradas pela Resolution: a tool negada nunca chega ao workflow" do
    got_tools = nil
    workflow_registry.register("flow", ->(_i, context:, tools:) { got_tools = tools; "ok" })
    tool_registry.register("permitida", poro_tool("permitida"))
    tool_registry.register("negada", poro_tool("negada"), optional: true) # optional sem opt-in -> deny
    executor = build_executor

    run(executor, make_task)

    names = got_tools.map { |t| t.__getobj__.name }
    expect(names).to include("permitida")
    expect(names).not_to include("negada")
  end

  it "WorkflowAllowlist: workflow fora de workflows_allow -> :policy_denied + task :failed, workflow nunca invocado" do
    invoked = false
    workflow_registry.register("flow", ->(*, **) { invoked = true })
    profile_no_wf = Harness::AgentProfile.build(id: "sales", model: "gpt",
                                                policies: %w[workflow_allowlist], workflows_allow: [])
    executor = Harness::Executor.new(
      context_builder: FakeContextBuilder.new,
      policy_engine: Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream),
      middleware: PassthroughMiddleware.new, hooks: Harness::Hooks.new,
      tool_registry: tool_registry, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: { "sales" => profile_no_wf }, session_store: session_store,
      task_store: task_store, checkpoint_store: checkpoint_store,
      event_stream: event_stream, workflow_registry: workflow_registry
    )

    Sync do
      executor.spawn(make_task, profile: profile_no_wf)
      executor.instance_variable_get(:@running)["t"]&.wait
    end

    expect(invoked).to be(false)
    expect(task_store.find("t").status).to eq(:failed)
    expect(event_stream.types).to include(:policy_denied)
  end

  it "workflow = 1 turno lógico: exatamente 1 checkpoint ao final; :done com o retorno" do
    workflow_registry.register("flow", ->(*, **) { 3.times.map { |i| "passo#{i}" }.last })
    executor = build_executor

    run(executor, make_task)

    expect(event_stream.types.count(:checkpoint_created)).to eq(1)
    expect(checkpoint_store.latest("t").turn).to eq(2)
    expect(event_stream.types).to include(:done, :task_completed)
  end

  it "exceção no workflow -> task :failed, :task_failed + :error" do
    workflow_registry.register("flow", ->(*, **) { raise "workflow explodiu" })
    executor = build_executor

    expect { run(executor, make_task) }.not_to raise_error

    expect(task_store.find("t").status).to eq(:failed)
    expect(event_stream.types).to include(:task_failed, :error)
  end

  it "side-effect + resume: tool side_effect não reexecuta na retomada (skip por nome)" do
    calls = 0
    tool_registry.register("charge", poro_tool("charge") { calls += 1 }, side_effect: true)
    # workflow chama a tool (envelopada) — na 1ª exec registra o side-effect
    workflow_registry.register("flow", ->(_i, context:, tools:) { tools.first.call({}); "ok" })
    executor = build_executor

    # Ato 1: monta estado pós-crash — turno 1 rodou a tool (side-effect na avulsa),
    # checkpoint turn 1, task running com Execution aberta.
    make_task
    task_store.begin_execution("t")
    task_store.transition("t", to: :running)
    checkpoint_store.save(Harness::Checkpoint.new(task_id: "t", turn: 1, session_id: nil,
                                                  agent_id: "sales", messages: [],
                                                  completed_side_effects: [], created_at: nil))
    checkpoint_store.record_side_effect("t", turn: 1, tool_call_id: "charge")

    # Ato 2: resume reexecuta o workflow do início; a tool "charge" está no skip set.
    Sync do
      executor.spawn(task_store.find("t"), profile: profile, resume_from: checkpoint_store.latest("t"))
      executor.instance_variable_get(:@running)["t"]&.wait
    end

    expect(calls).to eq(0) # a tool NÃO reexecutou (skip por nome)
    expect(task_store.find("t").status).to eq(:completed)
    expect(task_store.find("t").executions.size).to eq(2) # nova Execution
  end
end
