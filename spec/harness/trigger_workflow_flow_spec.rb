# frozen_string_literal: true

require "spec_helper"
require "async"

# Stage 6 variant integration (workflow) — fake PORO workflow, fake
# collaborators from the task 12 suite. No ruby_llm.
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

  # The Engine emits :policy_denied on ITS OWN stream; the Executor is the
  # correlated source (with seq) on the pipeline stream (doc 03 L3). Separate
  # streams avoid a duplicate event — wiring decision (task 26).
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

  # Tool PORO as a callable INSTANCE with #name (the workflow calls tool.call).
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

  it "invokes the workflow with input, context (ContextPackage) and tools (filtered instances)" do
    seen = {}
    workflow_registry.register("flow", lambda { |input, context:, tools:|
      seen[:input] = input
      seen[:context] = context
      seen[:tools] = tools
      "resultado do workflow"
    })
    # policy allows the tool "t" (via ToolAllowlist, allow nil -> all required)
    tool_registry.register("t", poro_tool("t"))
    executor = build_executor

    run(executor, make_task(input: { "q" => "x" }))

    expect(seen[:input]).to eq({ "q" => "x" })
    expect(seen[:context]).to be_a(ContextPackage)
    expect(seen[:tools].map { |t| t.__getobj__ }).to all(respond_to(:name)) # enveloped instances
    stored = task_store.find("t")
    expect(stored.status).to eq(:completed)
    done = event_stream.events.find { |e| e.type == :task_completed }
    expect(done.data[:content]).to eq("resultado do workflow")
  end

  it "tools filtered by the Resolution: the denied tool never reaches the workflow" do
    got_tools = nil
    workflow_registry.register("flow", ->(_i, context:, tools:) { got_tools = tools; "ok" })
    tool_registry.register("allowed", poro_tool("allowed"))
    tool_registry.register("negada", poro_tool("negada"), optional: true) # optional without opt-in -> deny
    executor = build_executor

    run(executor, make_task)

    names = got_tools.map { |t| t.__getobj__.name }
    expect(names).to include("allowed")
    expect(names).not_to include("negada")
  end

  it "WorkflowAllowlist: workflow outside workflows_allow -> :policy_denied + task :failed, workflow never invoked" do
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
    # exactly 1 :policy_denied on the pipeline (the Executor's correlated one) —
    # no duplicate (the Engine's went to engine_stream).
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

  it "workflow = 1 logical turn: exactly 1 checkpoint at the end; :task_completed with the return" do
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

  it "emits :workflow_started and :workflow_completed carrying run_id + typed I/O (item 22 / §4.4)" do
    workflow_registry.register("flow", ->(input, **) { { "echo" => input } })
    executor = build_executor

    run(executor, make_task(input: { "q" => "x" }))

    started = event_stream.events.find { |e| e.type == :workflow_started }
    completed = event_stream.events.find { |e| e.type == :workflow_completed }
    expect(started.data).to include(run_id: "t", workflow: "flow", input: { "q" => "x" })
    expect(completed.data).to include(run_id: "t", workflow: "flow", output: { "echo" => { "q" => "x" } })
    # runId == the terminal task's id (the durable run record).
    expect(started.meta[:task_id]).to eq("t")
  end

  it "output that violates output_schema -> task :failed at :workflow_schema, no :workflow_completed" do
    workflow_registry.register(
      "flow", ->(*, **) { { "wrong" => true } },
      output_schema: { "type" => "object", "properties" => { "ok" => { "type" => "boolean" } }, "required" => ["ok"] }
    )
    executor = build_executor

    run(executor, make_task)

    task = task_store.find("t")
    expect(task.status).to eq(:failed)
    expect(task.executions.last.error["stage"]).to eq("workflow_schema")
    expect(task.executions.last.error["class"]).to eq("Harness::WorkflowSchemaError")
    expect(event_stream.types).to include(:workflow_started, :task_failed)
    expect(event_stream.types).not_to include(:workflow_completed)
  end

  it "conforming output passes validation and completes normally" do
    workflow_registry.register(
      "flow", ->(*, **) { { "ok" => true } },
      output_schema: { "type" => "object", "properties" => { "ok" => { "type" => "boolean" } }, "required" => ["ok"] }
    )
    executor = build_executor

    run(executor, make_task)

    expect(task_store.find("t").status).to eq(:completed)
    expect(event_stream.types).to include(:workflow_completed, :task_completed)
  end

  it "side-effect + resume: side_effect tool does not re-run on resume (skip by name)" do
    calls = 0
    tool_registry.register("charge", poro_tool("charge") { calls += 1 }, side_effect: true)
    # the workflow calls the tool (enveloped) — on the 1st exec it records the side-effect
    workflow_registry.register("flow", ->(_i, context:, tools:) { tools.first.call({}); "ok" })
    executor = build_executor

    # Act 1: builds the post-crash state — turn 1 ran the tool (standalone side-effect),
    # checkpoint turn 1, task running with an open Execution.
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

    expect(calls).to eq(0) # the tool did NOT re-execute (skip by name)
    expect(task_store.find("t").status).to eq(:completed)
    expect(task_store.find("t").executions.size).to eq(2) # new Execution
  end
end
