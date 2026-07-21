# frozen_string_literal: true

require "spec_helper"
require "async"

# Stage 6 variant integration (workflow) — fake PORO workflow, collaborators
# fake da suíte da task 12. Sem ruby_llm.
RSpec.describe "Executor: trigger_workflow (stage 6 variant)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:workflow_registry) { Harness::WorkflowRegistry.new }
  let(:tool_registry) { Harness::ToolRegistry.new }
  # profile with WorkflowAllowlist in the policies + allowed workflow
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

  # O Engine emite :policy_denied no SEU stream; o Executor é a fonte
  # correlacionada (com seq) no stream da pipeline (doc 03 L3). Streams
  # separated avoid a duplicate event — wiring decision (task 26).
  let(:engine_stream) { SpyEventStream.new }

  def build_executor(allowed_tools: [])
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new,
      policy_engine: Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: engine_stream),
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
    done = event_stream.events.find { |e| e.type == :task_completed }
    expect(done.data[:content]).to eq("resultado do workflow")
  end

  it "tools filtradas pela Resolution: a tool negada nunca chega ao workflow" do
    got_tools = nil
    workflow_registry.register("flow", ->(_i, context:, tools:) { got_tools = tools; "ok" })
    tool_registry.register("allowed", poro_tool("allowed"))
    tool_registry.register("negada", poro_tool("negada"), optional: true) # optional sem opt-in -> deny
    executor = build_executor

    run(executor, make_task)

    names = got_tools.map { |t| t.__getobj__.name }
    expect(names).to include("allowed")
    expect(names).not_to include("negada")
  end

  it "WorkflowAllowlist: workflow fora de workflows_allow -> :policy_denied + task :failed, workflow nunca invocado" do
    invoked = false
    workflow_registry.register("flow", ->(*, **) { invoked = true })
    profile_no_wf = Harness::AgentProfile.build(id: "sales", model: "gpt",
                                                policies: %w[workflow_allowlist], workflows_allow: [])
    executor = Harness::Executor.new(
      context_builder: FakeContextBuilder.new,
      policy_engine: Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: engine_stream),
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
    # exatamente 1 :policy_denied na pipeline (o correlacionado do Executor) —
    # sem duplicata (o do Engine foi p/ engine_stream).
    expect(event_stream.types.count(:policy_denied)).to eq(1)
    expect(event_stream.events.find { |e| e.type == :policy_denied }.meta[:seq]).to be_a(Integer)
  end

  it "omitted input: workflow receives {} (not nil)" do
    got = :unset
    workflow_registry.register("flow", ->(input, **) { got = input; "ok" })
    executor = build_executor
    command = Harness::Command.build(:trigger_workflow, { workflow: "flow", agent: "sales" })
    task = task_store.create(command: command.to_h, id: "t")

    run(executor, task)

    expect(got).to eq({})
    expect(task_store.find("t").status).to eq(:completed)
  end

  it "workflow = 1 turno lógico: exatamente 1 checkpoint ao final; :task_completed com o retorno" do
    workflow_registry.register("flow", ->(*, **) { 3.times.map { |i| "passo#{i}" }.last })
    executor = build_executor

    run(executor, make_task)

    expect(event_stream.types.count(:checkpoint_created)).to eq(1)
    expect(checkpoint_store.latest("t").turn).to eq(2)
    expect(event_stream.types).to include(:task_completed)
  end

  it "exception in the workflow -> task :failed, :task_failed" do
    workflow_registry.register("flow", ->(*, **) { raise "workflow explodiu" })
    executor = build_executor

    expect { run(executor, make_task) }.not_to raise_error

    expect(task_store.find("t").status).to eq(:failed)
    expect(event_stream.types).to include(:task_failed)
    expect(event_stream.types).not_to include(:error) # R2b: no legacy twin
  end

  it "side-effect + resume: side_effect tool does not re-run on resume (skip by name)" do
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

    # Act 2: resume re-runs the workflow from the start; the "charge" tool is in the skip set.
    Sync do
      executor.spawn(task_store.find("t"), profile: profile, resume_from: checkpoint_store.latest("t"))
      executor.instance_variable_get(:@running)["t"]&.wait
    end

    expect(calls).to eq(0) # a tool NÃO reexecutou (skip por nome)
    expect(task_store.find("t").status).to eq(:completed)
    expect(task_store.find("t").executions.size).to eq(2) # nova Execution
  end
end
