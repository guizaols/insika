# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/condition"

RSpec.describe "Insika::Executor pipeline (stages 2-9)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  def build_executor(**over)
    defaults = {
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    }
    Insika::Executor.new(**defaults.merge(over))
  end

  def make_task(session_id: "s1", message: "oi", history: nil)
    payload = { agent: "sales", message: message }
    payload[:history] = history if history
    command = Insika::Command.build(:send_message, payload)
    task_store.create(command: command.to_h, session_id: session_id, id: "t")
  end

  # Runs the turn to completion (the fiber completes synchronously with a non-suspended FakeChat).
  def run_turn(executor, task, fake_chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(fake_chat)
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  # A data-tool with `halt_when` ends the turn from its RESULT: the backend already
  # answered the customer (it performed the side effect AND sent the confirmation), so
  # a second message from the model would be a duplicate. RubyLLM returns the
  # Tool::Halt in place of a Message; the turn must complete with NO text.
  describe "turn halted by a tool result (halt_when)" do
    it "keeps what was streamed before the call and never the tool payload" do
      session_store.create(id: "s1")
      executor = build_executor
      chat = FakeChat.new
      chat.script = -> { emit_chunk("vou te inscrever agora") } # the model's lead-in
      chat.halt_with!('{"tool_result":{"status":"SUBSCRIBED"}}')

      run_turn(executor, make_task, fake_chat: chat)

      completed = event_stream.events.find { |e| e.type == :task_completed }
      expect(completed).not_to be_nil                                  # a completion, not a failure
      expect(completed.data[:content]).to eq("vou te inscrever agora") # the stream, verbatim
      expect(completed.data[:content]).not_to include("SUBSCRIBED")    # never the envelope
      expect(completed.data[:usage]).to be_nil                         # Halt carries no token counts
    end

    it "nothing streamed -> empty turn, which is what the consumer suppresses" do
      session_store.create(id: "s1")
      executor = build_executor
      chat = FakeChat.new
      chat.script = -> {} # the tool halted before the model said anything
      chat.halt_with!('{"tool_result":{"status":"SUBSCRIBED"}}')

      run_turn(executor, make_task, fake_chat: chat)

      expect(event_stream.events.find { |e| e.type == :task_completed }.data[:content]).to eq("")
    end

    it "emits no :content — the consumer has nothing to deliver" do
      session_store.create(id: "s1")
      executor = build_executor
      chat = FakeChat.new
      chat.script = -> {} # no chunks: the model never got to speak
      chat.halt_with!('{"tool_result":{"status":"SUBSCRIBED"}}')

      run_turn(executor, make_task, fake_chat: chat)

      expect(event_stream.events.map(&:type)).not_to include(:content)
    end
  end

  describe "token usage in the terminal event (observability)" do
    TokenResponse = Struct.new(:content, :input_tokens, :output_tokens, :model_id)

    it "captures input/output/total/model from the response -> :task_completed" do
      session_store.create(id: "s1")
      executor = build_executor
      chat = FakeChat.new
      allow(chat).to receive(:ask).and_return(TokenResponse.new("oi", 12, 8, "deepseek-chat"))

      run_turn(executor, make_task, fake_chat: chat)

      ev = event_stream.events.find { |e| e.type == :task_completed }
      expect(ev.data[:usage]).to eq(input_tokens: 12, output_tokens: 8, total_tokens: 20, model: "deepseek-chat")
    end

    it "response without token counts -> usage nil (does not invent zeros)" do
      session_store.create(id: "s1")
      executor = build_executor
      run_turn(executor, make_task) # FakeChat::Response = Struct.new(:content), no tokens

      expect(event_stream.events.find { |e| e.type == :task_completed }.data[:usage]).to be_nil
    end

    it "surfaces prompt-cache read + write tokens when the provider reports them (R3)" do
      executor = build_executor
      resp = Struct.new(:input_tokens, :output_tokens, :model_id, :cached_tokens, :cache_creation_tokens)
                   .new(100, 20, "claude", 80, 4096)

      usage = executor.send(:usage_of, resp)

      expect(usage).to include(
        input_tokens: 100, output_tokens: 20, total_tokens: 120,
        cached_tokens: 80, cache_creation_tokens: 4096, model: "claude"
      )
    end
  end

  describe "happy path with session" do
    it "emits the stages in order and persists (stage 8 in L4 order)" do
      session_store.create(id: "s1")
      executor = build_executor
      order = []
      allow(checkpoint_store).to receive(:save).and_wrap_original { |m, *a| order << :checkpoint; m.call(*a) }
      allow(session_store).to receive(:append_messages).and_wrap_original { |m, *a| order << :session; m.call(*a) }
      allow(task_store).to receive(:finish_execution).and_wrap_original { |m, *a, **kw| order << :finish; m.call(*a, **kw) }
      allow(task_store).to receive(:transition).and_wrap_original do |m, id, **kw|
        order << [:transition, kw[:to]]; m.call(id, **kw)
      end

      run_turn(executor, make_task)

      # 1st:checkpoint = turn's initial one (crash resumability);
      # then stage 8's order: checkpoint -> session -> finish -> transition
      expect(order).to eq([[:transition, :running], :checkpoint, :checkpoint, :session, :finish,
                           [:transition, :completed]])
      # turn events. The chunk rides :intermediate as it arrives and the SAME text
      # is published as :content when the message ends — one is the live stream, the
      # other is the answer, and only the second crosses /v1/responses.
      expect(event_stream.types).to eq(
        %i[task_started intermediate content checkpoint_created task_completed]
      )
      # final state
      task = task_store.find("t")
      expect(task.status).to eq(:completed)
      expect(task.executions.last.outcome).to eq("completed")
      # turn 2 checkpoint with transcript + agent_id
      cp = checkpoint_store.latest("t")
      expect(cp.turn).to eq(2)
      expect(cp.agent_id).to eq("sales")
      expect(cp.messages.map { |m| m["role"] }).to eq(%w[user assistant])
      # session received the 2 new messages
      expect(session_store.find("s1").messages.map { |m| m["content"] }).to eq(["oi", "final"])
    end
  end

  describe " R1 — persistence of tool calls/results (fidelity across turns)" do
    # Mimics RubyLLM: #ask appends the turn's REAL exchange to #messages (the shared
    # FakeChat does not — that is what the {user, assistant} fallback covers).
    let(:recording_chat) do
      Class.new(FakeChat) do
        def ask(message)
          add_message(role: :user, content: message)
          tc = FakeChat::ToolCall.new("search", { "q" => "x" }, "c1")
          add_message(role: :assistant, content: "", tool_calls: { "c1" => tc })
          add_message(role: :tool, content: "resultado da tool", tool_call_id: "c1")
          add_message(role: :assistant, content: "RAW #{final_content}")
          FakeChat::Response.new(final_content)
        end
      end.new
    end

    it "persists the whole turn: user, assistant(tool_calls), tool, final assistant" do
      session_store.create(id: "s1")
      recording_chat.final_content = "resposta final"

      run_turn(build_executor, make_task, fake_chat: recording_chat)

      msgs = session_store.find("s1").messages
      expect(msgs.map { |m| m["role"] }).to eq(%w[user assistant tool assistant])
      expect(msgs[1]["tool_calls"]).to eq([{ "id" => "c1", "name" => "search", "arguments" => { "q" => "x" } }])
      expect(msgs[2]).to include("role" => "tool", "tool_call_id" => "c1", "content" => "resultado da tool")
    end

    it "the final assistant bubble carries the REDACTED text, not the gem's raw" do
      session_store.create(id: "s1")
      recording_chat.final_content = "resposta final"

      run_turn(build_executor, make_task, fake_chat: recording_chat)

      expect(session_store.find("s1").messages.last)
        .to include("role" => "assistant", "content" => "resposta final")
    end

    it "the checkpoint records the turn's FLAT list (the provider regroups on read)" do
      session_store.create(id: "s1")
      recording_chat.final_content = "ok"

      run_turn(build_executor, make_task, fake_chat: recording_chat)

      cp = checkpoint_store.latest("t")
      expect(cp.messages.map { |m| m["role"] }).to eq(%w[user assistant tool assistant])
      expect(cp.messages).to all(be_a(Hash)) # flat, no nested Arrays
    end

    it "FakeChat that does NOT record messages -> {user, assistant} fallback (compat preserved)" do
      session_store.create(id: "s1")
      run_turn(build_executor, make_task) # default FakeChat: #ask does not populate #messages

      expect(session_store.find("s1").messages.map { |m| m["role"] }).to eq(%w[user assistant])
    end

    it "truncates role:tool > 4k on persistence (the full result stays in the ToolTraceStore)" do
      clipped = build_executor.send(:clip_tool_content, "a" * 5_000)
      expect(clipped).to start_with("a" * 4_000)
      expect(clipped).to include("truncated")
      expect(clipped.length).to be < 5_000
    end
  end

  describe "typed command (single source string||symbol)" do
    def task_with(command)
      Struct.new(:command, :session_id).new(command, nil)
    end

    it "reads the payload by string OR symbol key via rebuild_command" do
      executor = build_executor
      sym = task_with({ type: :send_message, payload: { message: "oi", history: [1] } })
      str = task_with({ "type" => "send_message", "payload" => { "message" => "oi", "history" => [1] } })

      [sym, str].each do |t|
        expect(executor.send(:extract_message, t)).to eq("oi")
        expect(executor.send(:command_history, t)).to eq([1])
        expect(executor.send(:command_type, t)).to eq("send_message") # always a String
      end
    end
  end

  describe "run_serial (session serialization,-03)" do
    it "spawn error marks the task :failed (does not orphan :queued without a terminal state)" do
      executor = build_executor
      task = make_task # status :queued
      allow(executor).to receive(:spawn).and_raise(Insika::Error, "spawn falhou")

      Sync { executor.run_serial(task, profile: profile) }

      expect(task_store.find("t").status).to eq(:failed)
      expect(event_stream.types).to include(:task_failed)
      expect(event_stream.types).not_to include(:error) # R2b: no legacy twin
    end
  end

  describe "one-shot (no session)" do
    it "does not touch the session but writes a checkpoint" do
      executor = build_executor
      expect(session_store).not_to receive(:append_messages)

      run_turn(executor, make_task(session_id: nil))

      expect(task_store.find("t").status).to eq(:completed)
      expect(checkpoint_store.latest("t").turn).to eq(2)
    end
  end

  describe "hooks around" do
    it "the Executor wraps :task (outer) and :agent (stage 6); :prompt stays in the Builder" do
      session_store.create(id: "s1")
      hooks = NullHooks.new
      executor = build_executor(hooks: hooks)

      run_turn(executor, make_task)

      # :task is the outermost, :agent at stage 6. :prompt belongs to the ContextBuilder
      # (not the Executor — avoids double-wrap). FakeContextBuilder does not use hooks.
      expect(hooks.pairs).to eq(%i[task agent])
    end
  end

  describe "PolicyDenied at stage 3" do
    it "emits :policy_denied + :task_failed and never builds the chat" do
      session_store.create(id: "s1")
      executor = build_executor(policy_engine: DenyAllPolicyEngine.new)
      expect(executor).not_to receive(:create_chat)

      Sync do
        executor.spawn(make_task, profile: profile)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      expect(event_stream.types).to include(:policy_denied, :task_failed)
      expect(event_stream.types).not_to include(:error) # R2b: no legacy twin
      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error).to include("stage" => "policy")
    end
  end

  describe "middleware halt" do
    it "fails the turn with halt_reason and never builds the chat" do
      session_store.create(id: "s1")
      executor = build_executor(middleware: HaltingMiddleware.new)
      expect(executor).not_to receive(:create_chat)

      Sync do
        executor.spawn(make_task, profile: profile)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["message"]).to include("rate limit")
    end
  end

  describe "real MiddlewareStack" do
    it "link that short-circuits with halt_reason -> task :failed, chat never built" do
      session_store.create(id: "s1")
      halting = Class.new(Insika::Middleware) do
        def call(state, &_nxt) = (state.halt_reason = "rate limit")
      end.new
      stack = Insika::MiddlewareStack.new([halting])
      executor = build_executor(middleware: stack)
      expect(executor).not_to receive(:create_chat)

      Sync do
        executor.spawn(make_task, profile: profile)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["message"]).to include("rate limit")
    end

    it "link that short-circuits WITHOUT halt_reason (edge case 4) -> generic failure" do
      session_store.create(id: "s1")
      silent = Class.new(Insika::Middleware) do
        def call(_state, &_nxt) = nil # does not call nxt, does not set halt_reason
      end.new
      executor = build_executor(middleware: Insika::MiddlewareStack.new([silent]))

      expect do
        Sync do
          executor.spawn(make_task, profile: profile)
          executor.instance_variable_get(:@running)["t"]&.wait
        end
      end.not_to raise_error

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["message"]).to include("without halt_reason")
    end

    it "real empty stack: turn completes normally" do
      session_store.create(id: "s1")
      executor = build_executor(middleware: Insika::MiddlewareStack.new([]))

      run_turn(executor, make_task)

      expect(task_store.find("t").status).to eq(:completed)
    end
  end

  describe "single capture" do
    it "ContextError -> task :failed with stage :context, fiber does not leak" do
      session_store.create(id: "s1")
      executor = build_executor(context_builder: RaisingContextBuilder.new)

      expect do
        Sync do
          executor.spawn(make_task, profile: profile)
          executor.instance_variable_get(:@running)["t"]&.wait
        end
      end.not_to raise_error

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["stage"]).to eq("context")
      expect(event_stream.types).to include(:task_failed)
      expect(event_stream.types).not_to include(:error) # R2b: no legacy twin
    end

    it "StoreError at stage 8 -> :failed stage :persistence + :task_failed" do
      session_store.create(id: "s1")
      executor = build_executor
      allow(checkpoint_store).to receive(:save).and_raise(Insika::StoreError, "disco cheio")

      run_turn(executor, make_task)

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["stage"]).to eq("persistence")
      expect(event_stream.types).to include(:task_failed)
    end
  end

  describe "turn timeout (via with_timeout)" do
    it "expires -> :failed with stage :turn" do
      session_store.create(id: "s1")
      fast = Insika::AgentProfile.build(id: "sales", model: "gpt", limits: { turn_timeout: 0.05 })
      executor = build_executor
      slow_chat = FakeChat.new
      slow_chat.script = proc { Async::Task.current.sleep(1) } # yields the fiber beyond the timeout
      allow(executor).to receive(:create_chat).and_return(slow_chat)

      Sync do
        executor.spawn(make_task, profile: fast)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["stage"]).to eq("turn")
    end
  end

  describe "tool timeout and side-effect (ToolEnvelope)" do
    # state profile with short timeouts (Data is frozen: build it, don't stub)
    let(:fast_profile) do
      Insika::AgentProfile.build(id: "s", model: "m", limits: { tool_timeout: 0.05 })
    end
    let(:state) do
      Insika::TurnState.new(task: task_store.create(command: { "type" => "x" }, id: "t"),
                             profile: fast_profile, turn: 1, message: "oi")
    end

    it "tool that times out returns {error:} to the model (turn continues)" do
      slow_tool = Class.new do
        def name = "lookup"
        def call(_args)
          Async::Task.current.sleep(1)
          "nunca"
        end
      end.new
      executor = build_executor
      wrapped = executor.send(:wrap_tools, [slow_tool], state)

      result = Sync { wrapped.first.call({}) }

      expect(result).to eq({ error: "TimeoutError: tool exceeded 0.05s" })
    end

    it "records the side-effect with the current tool_call_id BEFORE the result returns" do
      fast_tool = Class.new do
        def name = "charge"
        def call(_args) = "ok"
      end.new
      executor = build_executor(tool_registry: FakeToolRegistry.new(side_effect_names: ["charge"]))
      state.current_tool_call = FakeChat::ToolCall.new("charge", {}, "call_42")
      wrapped = executor.send(:wrap_tools, [fast_tool], state)

      Sync { wrapped.first.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to eq(["call_42"])
    end
  end

  describe "turn timeout while INSIDE a tool (Finding 1: must not be swallowed)" do
    it "the turn timeout wins and fails with stage :turn (does not become a tool {error})" do
      session_store.create(id: "s1")
      fast = Insika::AgentProfile.build(id: "sales", model: "gpt",
                                         limits: { turn_timeout: 0.05, tool_timeout: 60 })
      # slow tool (within the 60s tool_timeout) invoked during stage 6;
      # the turn_timeout (0.05s) expires WHILE the fiber is inside the tool.
      slow_tool = Class.new do
        def name = "lookup"
        def call(_args)
          Async::Task.current.sleep(1)
          "nunca"
        end
      end.new
      chat = FakeChat.new
      chat.script = proc { @tools.first.call({}) } # invokes the enveloped tool (stage 6)
      executor = build_executor(policy_engine: NullPolicyEngine.new(allowed_tools: [slow_tool]))
      allow(executor).to receive(:create_chat).and_return(chat)

      Sync do
        executor.spawn(make_task, profile: fast)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["stage"]).to eq("turn")
    end
  end

  describe "cleanup failure AFTER transition(:completed) (Finding 2: does not leak from the fiber)" do
    it "a failing prune does not re-fail the turn; task stays :completed and nothing leaks" do
      session_store.create(id: "s1")
      executor = build_executor
      allow(checkpoint_store).to receive(:prune).and_raise(Insika::StoreError, "prune caiu")

      expect { run_turn(executor, make_task) }.not_to raise_error

      task = task_store.find("t")
      expect(task.status).to eq(:completed) # durability preserved
      # prune is swallowed locally (best-effort): the turn still ends on its
      # success terminal, with no :error.
      expect(event_stream.types).to include(:task_completed)
      expect(event_stream.types).not_to include(:error)
    end
  end

  describe "resume path" do
    # Builds post-crash state (task running, open execution) + checkpoint.
    def seed_crashed(turn:, messages: [], side_effect_id: nil)
      task = make_task
      task_store.begin_execution("t")
      task_store.transition("t", to: :running)
      cp = Insika::Checkpoint.new(task_id: "t", turn: turn, session_id: "s1", agent_id: "sales",
                                   messages: messages, completed_side_effects: [], created_at: nil)
      checkpoint_store.save(cp)
      checkpoint_store.record_side_effect("t", turn: turn, tool_call_id: side_effect_id) if side_effect_id
      [task, cp]
    end

    it "re-executes the turn from the checkpoint, opens a new Execution and saves the next turn" do
      session_store.create(id: "s1")
      executor = build_executor
      task, cp = seed_crashed(turn: 3, messages: [{ "role" => "user", "content" => "anterior" }])
      fake = FakeChat.new
      allow(executor).to receive(:create_chat).and_return(fake)

      Sync do
        executor.spawn(task, profile: profile, resume_from: cp)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      stored = task_store.find("t")
      expect(stored.status).to eq(:completed)
      expect(stored.executions.size).to eq(2) # attempt 1 (interrupted) preserved + attempt 2
      expect(stored.executions.first.outcome).to eq("interrupted")
      expect(checkpoint_store.latest("t").turn).to eq(4) # turn 3 + 1
      # checkpoint history (precedence) was seeded into the chat
      expect(fake.messages.map { |m| m[:content] }).to eq(["anterior"])
    end

    it "skips the already-completed tool call (id in the skip set) and executes a new id" do
      spy = Class.new do
        attr_reader :calls

        def initialize = (@calls = 0)
        def name = "send"
        def call(_args) = (@calls += 1) && "ok"
      end.new
      session_store.create(id: "s1")
      executor = build_executor(policy_engine: NullPolicyEngine.new(allowed_tools: [spy]))
      task, cp = seed_crashed(turn: 1, side_effect_id: "call_done")
      fake = FakeChat.new
      fake.script = proc do
        fire_tool_call(name: "send", id: "call_done")
        r1 = @tools.first.call({})
        fire_tool_result(r1)
        fire_tool_call(name: "send", id: "call_new")
        r2 = @tools.first.call({})
        fire_tool_result(r2)
      end
      allow(executor).to receive(:create_chat).and_return(fake)

      Sync do
        executor.spawn(task, profile: profile, resume_from: cp)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      # only the new call (call_new) executed; call_done was skipped (marker)
      expect(spy.calls).to eq(1)
      results = event_stream.events.select { |e| e.type == :tool_result }.map { |e| e.data[:result] }
      expect(results.first).to include("already_executed")
    end
  end

  describe "cancel on the boundary" do
    it "-> :cancelled; previous checkpoint intact; no event after :task_cancelled" do
      session_store.create(id: "s1")
      executor = build_executor
      gate = Async::Condition.new
      chat = FakeChat.new
      chat.script = proc { gate.wait } # yields the fiber at stage 6
      allow(executor).to receive(:create_chat).and_return(chat)

      Sync do
        executor.spawn(make_task, profile: profile)
        actor = executor.instance_variable_get(:@running)["t"]
        executor.cancel("t") # posts :cancel while the ask waits
        gate.signal # ask returns; next drain (stage 8) sees the cancel
        actor.wait
      end

      task = task_store.find("t")
      expect(task.status).to eq(:cancelled)
      # the turn's INITIAL checkpoint (turn 1) was written at the start of the turn;
      # the cancel happened before stage 8, so there is NO completion checkpoint
      # (turn 2) — the turn did not advance (a :cancelled task is terminal, Recovery
      # does not resume it).
      expect(checkpoint_store.latest("t").turn).to eq(1)
      # :task_cancelled is the terminal (no legacy :error twin after it, R2b)
      expect(event_stream.types.last).to eq(:task_cancelled)
    end
  end

  # L4 (principle: execution belongs to the RUNTIME, not the connection). Under
  # HTTP the spawn runs in the request's fiber; the injected supervisor decouples the
  # turn from it to survive a disconnect.
  describe "ownership of the turn's fiber (supervisor)" do
    def blocking_executor(gate)
      executor = build_executor
      chat = FakeChat.new
      chat.script = proc { gate.wait } # blocks at stage 6 until released
      allow(executor).to receive(:create_chat).and_return(chat)
      executor
    end

    # Cooperative poll (no fixed window — robust in CI): yields the fiber until the
    # condition becomes true or ~2s elapses.
    def poll_until(top)
      200.times do
        return true if yield

        top.sleep(0.01)
      end
      yield
    end

    it "supervised: the turn survives the stop of the request's fiber and completes" do
      session_store.create(id: "s1")
      gate = Async::Condition.new
      executor = blocking_executor(gate)
      executor.supervised = true # serving arm (the supervisor is created lazily)

      Sync do |top|
        request = top.async do |req|
          executor.spawn(make_task, profile: profile)
          req.sleep(3600) # the request "holds the connection" (e.g., SSE)
        end
        expect(poll_until(top) { executor.running?("t") }).to be(true)
        actor = executor.instance_variable_get(:@running)["t"]

        request.stop # client disconnect: kills the request's subtree
        top.sleep(0.05) # gives ticks for the cancellation to propagate, IF it were a child
        expect(executor.running?("t")).to be(true) # turn was NOT cancelled (L4)

        gate.signal      # releases stage 6
        actor.wait       # deterministic completion (no fixed window)
        expect(task_store.find("t").status).to eq(:completed)
        executor.instance_variable_get(:@supervisor)&.stop # lets the Sync exit
      end
    end

    it "non-supervised (default): the turn is a child of the request and DIES with it" do
      session_store.create(id: "s1")
      gate = Async::Condition.new
      executor = blocking_executor(gate)

      Sync do |top|
        request = top.async do |_req|
          executor.spawn(make_task, profile: profile)
          Async::Task.current.sleep(3600)
        end
        expect(poll_until(top) { executor.running?("t") }).to be(true)

        request.stop # without a supervisor, the turn is a child of the request -> cancelled
        expect(poll_until(top) { !executor.running?("t") }).to be(true)
      end
    end
  end

  describe "per-turn timing breakdown (opt-in via INSIKA_TURN_TIMING)" do
    it "omits :timing from the terminal event when disabled (default)" do
      allow(Insika::TurnTiming).to receive(:enabled?).and_return(false)
      session_store.create(id: "s1")
      executor = build_executor
      run_turn(executor, make_task)

      ev = event_stream.events.find { |e| e.type == :task_completed }
      expect(ev.data).not_to have_key(:timing)
    end

    it "attaches prep/ttft/gen/total (ms) to the terminal event when enabled" do
      allow(Insika::TurnTiming).to receive(:enabled?).and_return(true)
      session_store.create(id: "s1")
      executor = build_executor
      run_turn(executor, make_task) # FakeChat emits one chunk -> first_token fires

      timing = event_stream.events.find { |e| e.type == :task_completed }.data[:timing]
      expect(timing.keys).to contain_exactly(:prep_ms, :ttft_ms, :gen_ms, :total_ms)
      expect(timing.values).to all(be_a(Numeric))
    end

    # The live :ttft frame was hand-built with its own meta: no seq and, worse,
    # no tenant — and a tenant-scoped /v1/events subscription is fail-closed on
    # meta[:tenant], so the tenant's own TTFB never reached the tenant.
    it "the live :ttft event carries the task's tenant (and its seq) like every other event" do
      allow(Insika::TurnTiming).to receive(:enabled?).and_return(true)
      session_store.create(id: "loja-a:s1")
      command = Insika::Command.build(:send_message, { agent: "sales", message: "oi" },
                                      tenant: "loja-a")
      task = task_store.create(command: command.to_h, session_id: "loja-a:s1", id: "t-tenant")
      run_turn(build_executor, task)

      ttft = event_stream.events.find { |e| e.type == :ttft }
      expect(ttft).not_to be_nil
      expect(ttft.meta).to include(tenant: "loja-a", task_id: "t-tenant")
      expect(ttft.meta[:seq]).to be_a(Integer)
      expect(Insika::EventStream::Subscription.new(tenant: "loja-a").matches?(ttft)).to be(true)
    end

    it "the live :ttft of a platform turn carries no tenant (parity)" do
      allow(Insika::TurnTiming).to receive(:enabled?).and_return(true)
      session_store.create(id: "s1")
      run_turn(build_executor, make_task)

      ttft = event_stream.events.find { |e| e.type == :ttft }
      expect(ttft.meta.key?(:tenant)).to be(false)
    end

    it "reasoning does NOT move the TTFB mark (first_token = first token the customer sees)" do
      allow(Insika::TurnTiming).to receive(:enabled?).and_return(true)
      session_store.create(id: "s1")
      executor = build_executor
      chat = FakeChat.new
      chat.script = proc do
        emit_thinking("deixa eu pensar")
        emit_chunk("oi")
      end
      run_turn(executor, make_task, fake_chat: chat)

      # A thinking-only turn would leave ttft unset; what we assert here is that the
      # mark exists because :content arrived — the reasoning never touches it.
      timing = event_stream.events.find { |e| e.type == :task_completed }.data[:timing]
      expect(timing[:ttft_ms]).to be_a(Numeric)
    end
  end

  describe "provider reasoning (:thinking) — internal, never the answer" do
    before { session_store.create(id: "s1") }

    it "emits chunk.thinking as :thinking deltas, out of the :content stream" do
      executor = build_executor
      chat = FakeChat.new
      chat.final_content = "Temos sim!"
      chat.script = proc do
        emit_thinking("o cliente quer trufas; ")
        emit_thinking("vou buscar no catálogo")
        emit_chunk("Temos sim!")
      end
      run_turn(executor, make_task, fake_chat: chat)

      thinking = event_stream.events.select { |e| e.type == :thinking }.map { |e| e.data[:delta] }
      expect(thinking).to eq(["o cliente quer trufas; ", "vou buscar no catálogo"])

      content = event_stream.events.select { |e| e.type == :content }.map { |e| e.data[:delta] }.join
      expect(content).to eq("Temos sim!")
    end

    it "keeps the reasoning out of the persisted turn and of the terminal content" do
      executor = build_executor
      chat = FakeChat.new
      chat.final_content = "Temos sim!"
      chat.script = proc do
        emit_thinking("deliberação interna")
        emit_chunk("Temos sim!")
      end
      run_turn(executor, make_task, fake_chat: chat)

      completed = event_stream.events.find { |e| e.type == :task_completed }
      expect(completed.data[:content]).to eq("Temos sim!")
      persisted = session_store.find("s1").messages.map { |m| m["content"] || m[:content] }.join
      expect(persisted).not_to include("deliberação interna")
    end

    it "a chunk with no thinking surface emits nothing (provider/fake duck-typing)" do
      executor = build_executor
      run_turn(executor, make_task) # FakeChat::Response has no #thinking

      expect(event_stream.types).not_to include(:thinking)
    end
  end

  # one entry per turn in the ContextTraceStore — tokens by category,
  # the tools estimate and the budget verdict. nil store / a builder without the
  # full package = off, and the turn is untouched either way.
  describe "context breakdown trace" do
    # A builder that returns the REAL package (the FakeContextBuilder in
    # spec/support is a 3-field Struct that predates fragments/budget).
    class BreakdownContextBuilder
      def call(_request)
        fragments = [
          Insika::ContextFragment.build(content: "identity", placement: :system, tokens: 400,
                                        source: "Insika::Context::Providers::Prompt", pinned: true),
          Insika::ContextFragment.build(content: [{ role: "user", content: "oi" }],
                                        placement: :history, tokens: 200,
                                        source: "Insika::Context::Providers::Session")
        ]
        Insika::ContextPackage.new(system: "identity", history: [], tool_context: nil,
                                   fragments: fragments,
                                   budget: { cap: 8_000, used: 600, evicted: [] })
      end
    end

    let(:fake_tool) do
      Class.new do
        def name = "search_products"
        def description = "Search the catalog"
        def parameters = { "query" => "string" }
      end.new
    end

    it "records one entry with the categories, tools and budget of the turn" do
      session_store.create(id: "s1")
      store = Insika::ContextTraceStore.new(store: backend)
      executor = build_executor(context_builder: BreakdownContextBuilder.new,
                                policy_engine: NullPolicyEngine.new(allowed_tools: [fake_tool]),
                                context_trace_store: store)

      run_turn(executor, make_task)

      got = store.for_session("s1")
      expect(got.size).to eq(1)
      entry = got.first
      expect(entry).to include("task_id" => "t", "turn" => 1, "cap" => 8_000, "used" => 600)
      expect(entry["categories"]).to eq(
        "prompt" => { "tokens" => 400, "fragments" => 1, "pinned" => 400 },
        "session" => { "tokens" => 200, "fragments" => 1, "pinned" => 0 }
      )
      expect(entry["tools"]["count"]).to eq(1)
      expect(entry["tools"]["tokens"]).to be > 0
    end

    # Once bodies arrive by context instead of a load_skill call, the trace is the
    # only after-the-fact record of WHICH skills a turn was given.
    it "records the fragment labels per category (which skills were injected)" do
      session_store.create(id: "s1")
      store = Insika::ContextTraceStore.new(store: backend)
      labelled = Class.new do
        def call(_request)
          fragments = [
            Insika::ContextFragment.build(content: "bodies", placement: :system, tokens: 900,
                                          source: "Insika::Context::Providers::SkillTrigger",
                                          labels: [{ "name" => "gift-concierge", "reason" => "eager" },
                                                   { "name" => "natura-line-expert", "reason" => "trigger:linha" }]),
            Insika::ContextFragment.build(content: "identity", placement: :system, tokens: 100,
                                          source: "Insika::Context::Providers::Prompt", pinned: true)
          ]
          Insika::ContextPackage.new(system: "x", history: [], tool_context: nil, fragments: fragments,
                                     budget: { cap: 8_000, used: 1_000, evicted: [] })
        end
      end.new

      run_turn(build_executor(context_builder: labelled, context_trace_store: store), make_task)

      cats = store.for_session("s1").first["categories"]
      expect(cats["skilltrigger"]["labels"]).to eq(
        [{ "name" => "gift-concierge", "reason" => "eager" },
         { "name" => "natura-line-expert", "reason" => "trigger:linha" }]
      )
      expect(cats["prompt"]).not_to have_key("labels")   # nothing to name -> no noise
    end

    # Correlation is the whole point of emitting here instead of in the provider:
    # the Studio's SSE drops an event whose meta lacks task_id when the subscriber
    # is task-scoped, so a provider-emitted event was correct and never arrived.
    describe "announcing skills injected by context (no load_skill call)" do
      def labelled_builder(labels)
        Class.new do
          define_method(:initialize) { |l| @l = l }
          def call(_request)
            frag = Insika::ContextFragment.build(
              content: "bodies", placement: :system, tokens: 900,
              source: "Insika::Context::Providers::SkillTrigger", labels: @l
            )
            Insika::ContextPackage.new(system: "x", history: [], tool_context: nil,
                                       fragments: [frag],
                                       budget: { cap: 8_000, used: 900, evicted: [] })
          end
        end.new(labels)
      end

      it "emits :skill_activated with the names, THE REASONS and full task/session correlation" do
        session_store.create(id: "s1")
        executor = build_executor(context_builder: labelled_builder(
          [{ "name" => "gift-concierge", "reason" => "trigger:presente" },
           { "name" => "mapa", "reason" => "eager" }]
        ))

        run_turn(executor, make_task)

        ev = event_stream.events.find { |e| e.type == :skill_activated }
        expect(ev).not_to be_nil
        expect(ev.data[:skills]).to eq(
          [{ name: "gift-concierge", reason: "trigger:presente" }, { name: "mapa", reason: "eager" }]
        )
        expect(ev.data[:source]).to eq("context")
        # without these the Studio filters the event out and nothing renders
        expect(ev.meta[:task_id]).to eq("t")
        expect(ev.meta[:session_id]).to eq("s1")
        expect(ev.meta[:seq]).to be_a(Integer)
      end

      it "does not emit when no skill body was injected" do
        session_store.create(id: "s1")
        run_turn(build_executor(context_builder: BreakdownContextBuilder.new), make_task)

        expect(event_stream.events.find { |e| e.type == :skill_activated }).to be_nil
      end

      # A plugin can supply a body through its own provider and has no reason to give.
      # Naming it `pack` beats printing a bare name: the operator still learns that
      # this one is neither theirs to trigger nor theirs to un-eager.
      it "a label with no reason is announced as `pack`" do
        session_store.create(id: "s1")
        executor = build_executor(context_builder: labelled_builder([{ "name" => "vendor-skill" }]))

        run_turn(executor, make_task)

        ev = event_stream.events.find { |e| e.type == :skill_activated }
        expect(ev.data[:skills]).to eq([{ name: "vendor-skill", reason: "pack" }])
      end

      # The one surface built to tell the truth must not be the one that lies. The
      # announcement is computed from the POST-BUDGET fragments, so a 2.6k-token body
      # the cut evicted is absent from the prompt AND absent from the card. Eviction is
      # the trace's `evicted` list to report, never an activation.
      it "never announces a body the budget evicted" do
        session_store.create(id: "s1")
        cut = Class.new do
          def call(_request)
            Insika::ContextPackage.new(
              system: "identity", history: [], tool_context: nil, fragments: [],
              budget: { cap: 100, used: 0, evicted: ["Insika::Context::Providers::SkillTrigger"] }
            )
          end
        end.new

        run_turn(build_executor(context_builder: cut), make_task)

        expect(event_stream.events.find { |e| e.type == :skill_activated }).to be_nil
      end
    end

    it "one-shot turn (no session) records nothing" do
      store = Insika::ContextTraceStore.new(store: backend)
      executor = build_executor(context_builder: BreakdownContextBuilder.new,
                                context_trace_store: store)

      run_turn(executor, make_task(session_id: nil))

      expect(store.for_session("")).to eq([])
    end

    it "a builder without the full package records nothing and the turn is untouched" do
      session_store.create(id: "s1")
      store = Insika::ContextTraceStore.new(store: backend)
      # Struct package (no fragments/budget) + store wired: no record, no error.
      executor = build_executor(context_trace_store: store)
      run_turn(executor, make_task)
      expect(event_stream.events.find { |e| e.type == :task_completed }).not_to be_nil
      expect(store.for_session("s1")).to eq([])
    end

    it "no store at all: the default path every other spec already runs" do
      session_store.create(id: "s1")
      run_turn(build_executor, make_task)
      expect(event_stream.events.find { |e| e.type == :task_completed }).not_to be_nil
    end
  end
end
