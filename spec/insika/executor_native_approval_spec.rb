# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Executor native approvals" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:checkpoints) { Insika::CheckpointStore.new(store: backend) }
  let(:pending) { Insika::PendingActionStore.new(store: backend) }
  let(:events) { SpyEventStream.new }
  let(:writes) { [] }
  let(:reads) { [] }
  let(:requests) { [] }
  let(:replies) { [] }
  let(:deferred) { [] }
  let(:allowed) { [writer, reader] }
  let(:profile) do
    Insika::AgentProfile.build(id: "a", model: "deepseek-v4-flash", provider: "deepseek",
      tools_allow: ["write", "read"], tools_deferred: deferred, approvals_required: ["write"])
  end
  let(:context) { RubyLLM.context { |config| config.deepseek_api_key = "spec-only" } }
  let(:writer) do
    sink = writes
    Class.new(RubyLLM::Tool) do
      parameter :amount, type: :integer, description: "Amount"
      define_method(:name) { "write" }
      define_method(:execute) { |amount:| sink << amount; "written #{amount}" }
    end.new
  end
  let(:reader) do
    sink = reads
    Class.new(RubyLLM::Tool) do
      define_method(:name) { "read" }
      define_method(:execute) { sink << "read"; "read result" }
    end.new
  end

  def executor
    policy = double(decide: Resolution.new(allowed, [], ["write"]))
    registry = FakeToolRegistry.new(side_effect_names: ["write"])
    allow(registry).to receive(:resolve).with("write").and_return(writer)
    catalog = double(search: [Insika::ToolCatalog::Entry.new(name: "write", description: "Write")])
    Insika::Executor.new(context_builder: FakeContextBuilder.new, policy_engine: policy,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: registry, tool_catalog: catalog, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "a" => profile }, session_store: sessions, task_store: tasks,
      checkpoint_store: checkpoints, pending_action_store: pending, event_stream: events, llm: context)
  end

  def calls(*entries, content: "")
    RubyLLM::Message.new(role: :assistant, content: content, tool_calls: entries.to_h do |id, name, args|
      [id, RubyLLM::ToolCall.new(id: id, name: name, arguments: args)]
    end, input_tokens: 10, output_tokens: 2)
  end

  def finish = RubyLLM::Message.new(role: :assistant, content: "done", input_tokens: 5, output_tokens: 1)

  before do
    sessions.create(id: "s")
    tasks.create(id: "t", session_id: "s", command: Insika::Command.build(:send_message,
      { agent: "a", message: "please write" }).to_h)
    allow_any_instance_of(RubyLLM::Providers::DeepSeek).to receive(:complete) do |_, messages, **, &stream|
      requests << messages.map(&:to_h)
      response = replies.shift || raise("unexpected model request")
      stream&.call(RubyLLM::Chunk.new(role: :assistant, content: response.content)) unless response.content.empty?
      response
    end
  end

  def wait_for_pending(top)
    top.with_timeout(2) do
      top.sleep(0.001) until (tasks.find("t").status == :waiting && !pending.open_for("t").empty?) ||
        %i[completed failed cancelled].include?(tasks.find("t").status)
    end
    expect(tasks.find("t").status).to eq(:waiting), tasks.find("t").inspect
    pending.open_for("t").first
  end

  def decide(runtime, action, decision)
    Insika::Commands::ApproveAction.new(pending_action_store: pending, executor: runtime, event_stream: events)
      .call(Insika::Command.build(:approve_action, { pending_id: action.id, decision: decision, operator: "operator" }))
  end

  def actor(runtime) = runtime.instance_variable_get(:@running)["t"]
  def stop(runtime) = actor(runtime)&.instance_variable_get(:@async_task)&.stop

  it "checkpoints stable calls and requires a separate decision for each write" do
    replies.concat([calls(["write-1", "write", { "amount" => 10 }], ["read-1", "read", {}]),
      calls(["write-2", "write", { "amount" => 20 }]), finish])
    runtime = executor
    Sync do |top|
      runtime.spawn(tasks.find("t"), profile: profile)
      first = wait_for_pending(top)
      expect(reads).to eq(["read"])
      expect(writes).to be_empty
      expect(first.id).to eq("t:1:call:write-1")
      saved = checkpoints.latest("t").continuation.fetch("messages")
      expect(saved.find { |message| message["tool_calls"] }.dig("tool_calls", 0, "id")).to eq("write-1")
      decide(runtime, first, :approved)
      second = wait_for_pending(top)
      expect(second.id).to eq("t:1:call:write-2")
      expect(writes).to eq([10])
      decide(runtime, second, :rejected)
      actor(runtime)&.wait
      expect(tasks.find("t").status).to eq(:completed)
      expect(writes).to eq([10])
    ensure
      stop(runtime)
    end
  end

  it "resumes the stored pending call without regenerating it or repeating its sibling" do
    replies.concat([calls(["write-1", "write", { "amount" => 10 }], ["read-1", "read", {}]), finish])
    first = executor
    resumed = nil
    Sync do |top|
      first.spawn(tasks.find("t"), profile: profile)
      action = wait_for_pending(top)
      stop(first)
      pending.resolve(action.id, decision: :approved, operator: "operator")
      checkpoint = Insika::CheckpointStore.new(store: backend).latest("t")
      resumed = executor
      resumed.spawn(tasks.find("t"), profile: profile, resume_from: checkpoint)
      actor(resumed)&.wait
      expect(tasks.find("t").status).to eq(:completed)
      expect(requests.size).to eq(2)
      expect(reads).to eq(["read"])
      expect(writes).to eq([10])
      messages = sessions.find("s").messages
      expect(messages.count { |message| message["role"] == "user" }).to eq(1)
      expect(messages.select { |message| message["role"] == "tool" }.map { |message| message["tool_call_id"] }).to contain_exactly("write-1", "read-1")
    ensure
      stop(first)
      stop(resumed) if resumed
    end
  end

  context "with a promoted deferred tool" do
    let(:deferred) { ["write"] }

    [false, true].each do |revoked|
      it "#{revoked ? 'does not restore a revoked tool' : 'restores the tool'} after restart" do
        replies.concat([calls(["search-1", "tool_search", { "query" => "write" }]),
          calls(["write-1", "write", { "amount" => 10 }]), finish])
        first = executor
        resumed = nil
        Sync do |top|
          first.spawn(tasks.find("t"), profile: profile)
          action = wait_for_pending(top)
          stop(first)
          pending.resolve(action.id, decision: :approved)
          allowed.delete(writer) if revoked
          resumed = executor
          resumed.spawn(tasks.find("t"), profile: profile, resume_from: checkpoints.latest("t"))
          actor(resumed)&.wait
          expect(tasks.find("t").status).to eq(:completed)
          expect(writes).to eq(revoked ? [] : [10])
          expect(requests.size).to eq(3)
        ensure
          stop(first)
          stop(resumed) if resumed
        end
      end
    end
  end

  it "closes unapproved sibling calls when a tool halts the turn" do
    replies << calls(["write-1", "write", { "amount" => 10 }], ["read-1", "read", {}])
    allow(reader).to receive(:execute).and_return(Insika::ToolDefinition::Halt.new(content: "stop"))
    runtime = executor
    Sync do
      runtime.spawn(tasks.find("t"), profile: profile)
      actor(runtime)&.wait
    ensure
      stop(runtime)
    end
    expect(tasks.find("t").status).to eq(:completed)
    expect(writes).to be_empty
    expect(pending.open_for("t")).to be_empty
    expect(requests.size).to eq(1)
    results = sessions.find("s").messages.select { |message| message["role"] == "tool" }
    expect(results.map { |message| message["tool_call_id"] }).to contain_exactly("write-1", "read-1")
    expect(results.find { |message| message["tool_call_id"] == "write-1" }.fetch("content")).to include("halted")
  end

  it "rejects existing sibling approvals when an approved tool halts" do
    replies << calls(["write-1", "write", { "amount" => 10 }], ["write-2", "write", { "amount" => 20 }])
    allow(writer).to receive(:execute) do |amount:|
      writes << amount
      Insika::ToolDefinition::Halt.new(content: "stop")
    end
    runtime = executor
    Sync do |top|
      runtime.spawn(tasks.find("t"), profile: profile)
      wait_for_pending(top)
      expect(pending.open_for("t").size).to eq(2)
      decide(runtime, pending.find("t:1:call:write-1"), :approved)
      actor(runtime)&.wait
      expect(tasks.find("t").status).to eq(:completed)
      expect(writes).to eq([10])
      expect(pending.open_for("t")).to be_empty
      expect(pending.find("t:1:call:write-1").status).to eq(:approved)
      rejected = pending.find("t:1:call:write-2")
      expect(rejected.status).to eq(:rejected)
      expect(rejected.resolved_by).to eq("engine:halted")
      expect(events.events.select { |event| event.type == :approval_resolved }.map(&:data))
        .to include(include(pending_id: rejected.id, decision: :rejected, resolved_by: "engine:halted"))
    ensure
      stop(runtime)
    end
  end

  [false, true].each do |recorded|
    it "preserves the halt lead-in after restart with a #{recorded ? 'recorded' : 'pending'} write" do
      replies << calls(["write-1", "write", { "amount" => 10 }], content: "Starting write")
      allow(writer).to receive(:execute) do |amount:|
        writes << amount
        Insika::ToolDefinition::Halt.new(content: "halted")
      end
      first = executor
      resumed = nil
      Sync do |top|
        first.spawn(tasks.find("t"), profile: profile)
        action = wait_for_pending(top)
        stop(first)
        pending.resolve(action.id, decision: :approved)
        if recorded
          writes << 10
          checkpoints.record_side_effect("t", turn: 1, tool_call_id: "write-1", halt: { "content" => "halted" })
        end
        resumed = executor
        resumed.spawn(tasks.find("t"), profile: profile, resume_from: checkpoints.latest("t"))
        actor(resumed)&.wait
        expect(tasks.find("t").status).to eq(:completed)
        expect(writes).to eq([10])
        expect(requests.size).to eq(1)
        expect(events.events.find { |event| event.type == :task_completed }.data.fetch(:content)).to eq("Starting write")
      ensure
        stop(first)
        stop(resumed) if resumed
      end
    end
  end

  it "rejects a stored decision whose arguments do not match the pending call" do
    pending.create(id: "t:1:call:write-1", task_id: "t", turn: 1, tool: "write", args: { "amount" => 999 })
    pending.resolve("t:1:call:write-1", decision: :approved)
    replies << calls(["write-1", "write", { "amount" => 10 }])
    runtime = executor
    Sync do
      runtime.spawn(tasks.find("t"), profile: profile)
      actor(runtime)&.wait
    ensure
      stop(runtime)
    end
    expect(tasks.find("t").status).to eq(:failed)
    expect(writes).to be_empty
  end

  it "resumes after a completed write without repeating it and preserves prior usage" do
    replies.concat([calls(["write-1", "write", { "amount" => 10 }]),
      calls(["write-2", "write", { "amount" => 20 }]), finish])
    first = executor
    resumed = nil
    Sync do |top|
      first.spawn(tasks.find("t"), profile: profile)
      decide(first, wait_for_pending(top), :approved)
      second = wait_for_pending(top)
      expect(writes).to eq([10])
      expect(checkpoints.side_effects("t", turn: 1)).to include("write-1")
      stop(first)
      pending.resolve(second.id, decision: :approved, operator: "operator")
      resumed = executor
      resumed.spawn(tasks.find("t"), profile: profile, resume_from: checkpoints.latest("t"))
      actor(resumed)&.wait
      expect(tasks.find("t").status).to eq(:completed)
      expect(writes).to eq([10, 20])
      expect(requests.size).to eq(3)
      usage = events.events.find { |event| event.type == :task_completed }.data.fetch(:usage)
      expect(usage).to include(input_tokens: 25, output_tokens: 5)
    ensure
      stop(first)
      stop(resumed) if resumed
    end
  end

  it "ignores an unresolved wakeup and permits cancellation while waiting" do
    replies << calls(["write-1", "write", { "amount" => 10 }])
    runtime = executor
    Sync do |top|
      runtime.spawn(tasks.find("t"), profile: profile)
      wait_for_pending(top)
      runtime.approve("t")
      top.sleep(0.01)
      expect(tasks.find("t").status).to eq(:waiting)
      expect(writes).to be_empty
      live = actor(runtime)
      live.post(:cancel)
      live.wait
      expect(tasks.find("t").status).to eq(:cancelled)
      expect(writes).to be_empty
    ensure
      stop(runtime)
    end
  end

  it "skips a spill-recorded write when the process died before saving its result" do
    replies.concat([calls(["write-1", "write", { "amount" => 10 }]), finish])
    first = executor
    resumed = nil
    Sync do |top|
      first.spawn(tasks.find("t"), profile: profile)
      action = wait_for_pending(top)
      stop(first)
      pending.resolve(action.id, decision: :approved)
      # The external write and its durable marker completed; the following
      # tool-result/checkpoint write did not. Recovery must not invoke it again.
      writes << 10
      checkpoints.record_side_effect("t", turn: 1, tool_call_id: "write-1")
      resumed = executor
      resumed.spawn(tasks.find("t"), profile: profile, resume_from: checkpoints.latest("t"))
      actor(resumed)&.wait
      expect(tasks.find("t").status).to eq(:completed)
      expect(writes).to eq([10])
      expect(sessions.find("s").messages.find { |message| message["tool_call_id"] == "write-1" }.fetch("content"))
        .to include("already_executed")
    ensure
      stop(first)
      stop(resumed) if resumed
    end
  end
end
