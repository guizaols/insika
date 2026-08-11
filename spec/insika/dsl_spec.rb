# frozen_string_literal: true

require "spec_helper"
require "async"
# WorkflowAdapter is only reached through `dsl/runtime`, which the System requires
# lazily — so an example that names the constant directly fails on the orderings where
# no earlier example built a runtime. Explicit here instead of order-dependent.
require "insika/dsl/workflow_adapter"

# Public Ruby DSL. Proves the two things the item is about:
#   1. the DSL GENERATES the data — Insika.agent { … }.to_pack is a plain Pack;
#   2. PARITY — the profile it produces is IDENTICAL to the one a hand-written
#      equivalent pack produces (there is one path: the standard import), so the
#      sugar never diverges from config-over-code.
# Plus the runtime surface (reply/chat) that makes the ≤10-line quickstart real.
RSpec.describe Insika::DSL do
  describe "Insika.agent → data generation (#to_pack)" do
    subject(:pack) do
      Insika.agent("assistant") do
        model "deepseek-chat"
        provider :deepseek
        instructions "You are a concise, friendly assistant."
        tools "menu", "calc"
        skill "escalate", description: "Escalate to a human", instructions: "Hand off when angry."
        memory true
        temperature 0.2
      end.to_pack
    end

    it "is a Insika::Pack carrying the manifest under config" do
      expect(pack).to be_a(Insika::Pack)
      expect(pack.config).to include(
        id: "assistant", model: "deepseek-chat", provider: "deepseek",
        base_prompt: "You are a concise, friendly assistant.",
        tools_allow: %w[menu calc], memory: true
      )
      expect(pack.config[:params]).to eq(temperature: 0.2)
    end

    it "auto-enables the allowlist policies (no hidden magic — visible in the pack)" do
      expect(pack.config[:policies]).to eq(%i[tool_allowlist skill_allowlist])
    end

    it "materializes each skill as a valid SKILL.md (frontmatter + body) and allowlists it" do
      expect(pack.config[:skills]).to eq(%w[escalate])
      md = pack.skills.fetch("escalate")
      expect(md).to match(/\A---\s*\nname: escalate\ndescription: Escalate to a human\n---/)
      expect(md).to include("Hand off when angry.")
    end

    it "data_tool adds a ToolDefinition AND allowlists its name" do
      pk = Insika.agent("shop") do
        model "m"
        data_tool("name" => "cart", "description" => "d", "request" => { "url" => "https://api.test" })
      end.to_pack
      expect(pk.tools.map { |t| t["name"] }).to eq(%w[cart])
      expect(pk.config[:tools_allow]).to include("cart")
    end

    it "guardrails(...) stores content-safety config on the pack (opt-in)" do
      pk = Insika.agent("safe") do
        model "m"
        guardrails input: true, output: true, strictness: "high",
                   responses: { "injection" => "I can't help with that." }
      end.to_pack
      expect(pk.config[:guardrails]).to eq(
        "input" => true, "output" => true, "strictness" => "high",
        "responses" => { "injection" => "I can't help with that." }
      )
    end

    it "guardrails config round-trips through import to Safety::Config" do
      profile = import_and_read(
        Insika.agent("safe") do
          model "m"
          guardrails input: true, output: true, strictness: "high"
        end.to_pack
      )
      cfg = Insika::Safety::Config.from_profile(profile)
      expect(cfg.input).to be(true)
      expect(cfg.output).to be(true)
      expect(cfg.strictness).to eq(:high)
    end

    # It decides nothing at runtime; it exists so an eval case can be
    # SKIPPED where the deployment lacks something, instead of failing for the wrong
    # reason — so the one thing that matters is that it survives the round-trip.
    it "declares(...) round-trips to capabilities_declared on the profile" do
      profile = import_and_read(
        Insika.agent("loja") do
          model "m"
          declares "promotions", "human_handoff"
        end.to_pack
      )

      expect(profile.capabilities_declared).to eq(%w[promotions human_handoff])
    end

    it "an agent that declares nothing carries an empty list, never nil" do
      expect(import_and_read(Insika.agent("x") { model "m" }.to_pack).capabilities_declared).to eq([])
    end

    it "edge_stream(...) round-trips to the profile, and absent means neither channel" do
      profile = import_and_read(
        Insika.agent("panel") do
          model "m"
          edge_stream thinking: true
        end.to_pack
      )

      expect(profile.stream_public?(:thinking)).to be(true)
      expect(profile.stream_public?(:intermediate)).to be(false)
      expect(import_and_read(Insika.agent("x") { model "m" }.to_pack).stream_public?(:thinking)).to be(false)
    end

    it "raw SKILL.md content (already has frontmatter) passes through untouched" do
      raw = "---\nname: promo\ndescription: promos\n---\n\nAlways mention the promo."
      pk = Insika.agent("x") { model "m"; skill "promo", raw }.to_pack
      expect(pk.skills.fetch("promo")).to eq(raw)
    end
  end

  # A lean authoring graph over Memory: imports any Pack via the standard
  # PackImporter and reads the profile back — the config-over-code round-trip.
  def import_and_read(pack)
    backend = Insika::Stores::Memory.new
    cs = Insika::ConfigStore.new(store: backend)
    profiles = Insika::StoredProfileSource.new(config_store: cs)
    afs = Insika::AgentFileStore.new(config_store: cs)
    ss = Insika::SkillStore.new(config_store: cs)
    ts = Insika::ToolStore.new(config_store: cs)
    es = Insika::EventStream.new
    reg = Insika::OverlayToolRegistry.new(base: Insika::ToolRegistry.new, tool_store: ts,
                                           http: Insika::HttpClient.new, event_stream: es)
    cat = Insika::ToolCatalog.new(tool_registry: reg)
    skill_cat = Insika::SkillCatalog.new([], store: ss)

    bus = Insika::CommandBus.new
    bus.register(:create_agent, Insika::Commands::CreateAgent.new(profile_source: profiles, event_stream: es))
    bus.register(:update_agent, Insika::Commands::UpdateAgent.new(profile_source: profiles, event_stream: es))
    bus.register(:write_agent_file, Insika::Commands::WriteAgentFile.new(profile_source: profiles, agent_file_store: afs, event_stream: es))
    bus.register(:write_skill, Insika::Commands::WriteSkill.new(skill_store: ss, skill_catalog: skill_cat, event_stream: es))
    bus.register(:write_data_tool, Insika::Commands::WriteDataTool.new(tool_store: ts, registry: reg, tool_catalog: cat, event_stream: es))

    Insika::PackImporter.new(bus: bus, profiles: profiles).import(pack)
    profiles.fetch(pack.config[:id])
  end

  describe "PARITY — DSL profile == hand-written equivalent pack" do
    let(:dsl_agent) do
      Insika.agent("bia") do
        model "deepseek-chat"
        provider :deepseek
        instructions "You are Bia."
        tools "menu", "calc"
        skill "escalate", description: "Escalate to a human", instructions: "Hand off when angry."
        memory true
      end
    end

    # The SAME agent authored by hand as a portable pack (what a non-Ruby caller
    # would ship). If these differ, the DSL is not faithfully generating the data.
    let(:hand_pack) do
      Insika::Pack.from_h(
        config: {
          id: "bia", model: "deepseek-chat", provider: "deepseek",
          base_prompt: "You are Bia.", tools_allow: %w[menu calc],
          skills: %w[escalate], memory: true,
          policies: %i[tool_allowlist skill_allowlist]
        },
        skills: {
          "escalate" => "---\nname: escalate\ndescription: Escalate to a human\n---\n\nHand off when angry.\n"
        }
      )
    end

    it "the generated pack round-trips to the SAME profile as the hand pack" do
      from_dsl = import_and_read(dsl_agent.to_pack)
      from_hand = import_and_read(hand_pack)
      expect(from_dsl).to eq(from_hand)
    end

    it "Definition#profile (its own runtime import) matches that profile too" do
      expect(dsl_agent.profile).to eq(import_and_read(hand_pack))
    end
  end

  describe "#reply / #chat (in-process turn — the quickstart's demo)" do
    let(:agent) do
      Insika.agent("assistant") do
        model "gpt"
        provider :deepseek
        instructions "You are helpful."
      end
    end

    # Scripted LLM: stub create_chat on the runtime's own Executor (no gem call).
    def with_scripted_llm(agent, final:, &script)
      chat = FakeChat.new
      chat.final_content = final
      chat.script = script || proc { emit_chunk(final) }
      agent.runtime.graph.executor.define_singleton_method(:create_chat) { |*_a, **_k| chat }
    end

    it "one-shot reply returns the assistant text" do
      with_scripted_llm(agent, final: "Hello there") { emit_chunk("Hello there") }
      expect(agent.reply("hi")).to eq("Hello there")
    end

    it "session reply threads a session (created on first use)" do
      with_scripted_llm(agent, final: "again") { emit_chunk("again") }
      expect(agent.reply("hi", session: "s1")).to eq("again")
      expect(agent.runtime.graph.session_store.find("s1")).not_to be_nil
    end

    it "imports the agent into the runtime's ProfileSource" do
      expect(agent.runtime.graph.profiles.fetch("assistant")).to be_a(Insika::AgentProfile)
    end
  end

  # Multi-agent DSL: the shape every agentic-workflow pattern needs. The claim
  # under test is that a System adds NO new engine path — N agents, N ordinary
  # packs, one graph, the same standard import.
  describe "Insika.system → several agents in one runtime" do
    subject(:system) do
      Insika.system do
        provider :deepseek

        agent "security" do
          model "deepseek-chat"
          instructions "Review code for security issues."
        end

        agent "performance" do
          model "deepseek-chat"
          instructions "Review code for performance issues."
        end

        agent "reviewer" do
          model "deepseek-chat"
          instructions "Delegate to the specialists, then synthesize."
          subagents "security", "performance"
        end
      end
    end

    it "generates one Pack per agent, in declaration order" do
      expect(system.to_packs.map { |p| p.config[:id] }).to eq(%w[security performance reviewer])
      expect(system.to_packs).to all(be_a(Insika::Pack))
    end

    it "carries `subagents` on the parent's pack (the delegation allowlist is data)" do
      reviewer = system.to_packs.last
      expect(reviewer.config[:subagents]).to eq(%w[security performance])
    end

    it "imports EVERY agent into one shared ProfileSource" do
      profiles = system.runtime.graph.profiles
      expect(%w[security performance reviewer].map { |id| profiles.fetch(id) })
        .to all(be_a(Insika::AgentProfile))
    end

    it "round-trips `subagents` through the import (what wires spawn_subagent)" do
      expect(system.profile("reviewer").subagents).to eq(%w[security performance])
      expect(system.profile("security").subagents).to be_nil # opt-in: absent = none
    end

    it "rejects a duplicate agent id" do
      expect do
        Insika.system do
          agent("dup") { model "m" }
          agent("dup") { model "m" }
        end
      end.to raise_error(ArgumentError, /duplicate agent id/)
    end

    it "rejects an empty system" do
      expect { Insika.system { nil } }.to raise_error(ArgumentError, /at least one agent/)
    end

    it "raises a clear NotFoundError for an agent outside the system" do
      expect { system.reply("nope", "hi") }
        .to raise_error(Insika::NotFoundError, /not in this system.*security/m)
    end

    describe "#reply targets one agent explicitly" do
      def with_scripted_llm(runtime, final:)
        chat = FakeChat.new
        chat.final_content = final
        chat.script = proc { emit_chunk(final) }
        runtime.graph.executor.define_singleton_method(:create_chat) { |*_a, **_k| chat }
      end

      it "dispatches the turn to the named agent" do
        with_scripted_llm(system.runtime, final: "reviewed")
        dispatched = []
        bus = system.runtime.graph.bus
        original = bus.method(:dispatch)
        bus.define_singleton_method(:dispatch) do |command|
          dispatched << command.payload[:agent] if command.type == :send_message
          original.call(command)
        end

        expect(system.reply("performance", "look at this")).to eq("reviewed")
        expect(dispatched).to eq(["performance"])
      end
    end

    # The point of the whole container: a parent declared with `subagents` can
    # actually delegate through the graph the DSL built. Without this the field
    # would be data nobody honours.
    it "the parent really delegates to a declared child (through the DSL graph)" do
      executor = system.runtime.graph.executor
      child_chat = FakeChat.new.tap do |c|
        c.final_content = "no SQL injection found"
        c.script = proc { emit_chunk("no SQL injection found") }
      end
      allow(executor).to receive(:create_chat).and_return(child_chat)

      task = system.runtime.graph.task_store.create(
        command: Insika::Command.build(:send_message, { agent: "reviewer", message: "go" }).to_h,
        session_id: nil, id: "parent-task"
      )
      state = Insika::TurnState.new(task: task, profile: system.profile("reviewer"), turn: 1, message: "go")
      state.turn_context = {}

      result = nil
      Sync { result = executor.run_subagent(agent: "security", message: "review this", parent_state: state) }

      expect(result[:text]).to eq("no SQL injection found")
      expect(result[:session_id]).not_to be_nil
    end

    it "refuses to delegate to an agent outside the parent's allowlist" do
      executor = system.runtime.graph.executor
      task = system.runtime.graph.task_store.create(
        command: Insika::Command.build(:send_message, { agent: "security", message: "go" }).to_h,
        session_id: nil, id: "leaf-task"
      )
      # `security` declares no subagents → opt-in means NONE, not "all".
      state = Insika::TurnState.new(task: task, profile: system.profile("security"), turn: 1, message: "go")
      state.turn_context = {}

      result = nil
      Sync { result = executor.run_subagent(agent: "performance", message: "x", parent_state: state) }

      expect(result[:error]).to match(/not allowed|allowlist|cannot/i)
    end
  end

  # Workflows from the DSL: deterministic Ruby around agent turns, registered in
  # the SAME WorkflowRegistry a deployment uses — so a DSL workflow is durable
  # (its run IS a Task), schema-validated at the edges, and discoverable.
  describe "Insika.system → workflows" do
    subject(:system) do
      Insika.system do
        agent("writer") { model "m"; instructions "write" }
        agent("editor") { model "m"; instructions "edit" }

        workflow "echo",
                 description: "Echoes its input — no model call.",
                 input: { type: "object", properties: { topic: { type: "string" } }, required: ["topic"] },
                 output: { type: "object", properties: { text: { type: "string" } } } do |input, _ctx|
          { "text" => input["topic"].upcase }
        end

        workflow("chain") { |input, ctx| { "text" => ctx.ask("writer", input["topic"].to_s) } }
      end
    end

    def script(runtime, final)
      chat = FakeChat.new
      chat.final_content = final
      chat.script = proc { emit_chunk(final) }
      runtime.graph.executor.define_singleton_method(:create_chat) { |*_a, **_k| chat }
    end

    it "registers them with description and schemas (the discovery catalog)" do
      catalog = system.runtime.graph.workflow_registry.catalog
      echo = catalog.find { |w| w["name"] == "echo" }

      expect(system.runtime.graph.workflow_registry.names).to eq(%w[echo chain])
      expect(echo["description"]).to eq("Echoes its input — no model call.")
      expect(echo["input_schema"]["required"]).to eq(["topic"])
    end

    it "#run returns the workflow's typed OUTPUT (not the turn text)" do
      expect(system.run("echo", input: { "topic" => "fibers" })).to eq({ "text" => "FIBERS" })
    end

    it "refuses a bad input synchronously, creating NO run" do
      expect { system.run("echo", input: { "nope" => 1 }) }
        .to raise_error(Insika::WorkflowSchemaError, /topic/)
      expect(system.runtime.graph.task_store.each_id.count).to eq(0)
    end

    it "raises NotFoundError for an unregistered workflow" do
      expect { system.run("nope", input: {}) }.to raise_error(Insika::NotFoundError, /not registered/)
    end

    it "ctx.ask runs a turn against the named agent" do
      script(system.runtime, "drafted")
      expect(system.run("chain", input: { "topic" => "x" })).to eq({ "text" => "drafted" })
    end

    it "ctx.gather runs blocks concurrently and returns them IN ORDER" do
      ctx = Insika::DSL::WorkflowAdapter::Context.new(runtime: system.runtime, context: nil, tools: [])
      expect(ctx.gather(-> { :a }, -> { :b }, -> { :c })).to eq(%i[a b c])
    end

    it "rejects a duplicate workflow name" do
      expect do
        Insika.system do
          agent("a") { model "m" }
          workflow("dup") { |_i, _c| 1 }
          workflow("dup") { |_i, _c| 2 }
        end
      end.to raise_error(ArgumentError, /duplicate workflow/)
    end

    it "a system with NO workflows does not register :trigger_workflow (parity)" do
      plain = Insika.system { agent("solo") { model "m" } }
      expect { plain.runtime.graph.bus.dispatch(Insika::Command.build(:trigger_workflow, {})) }
        .to raise_error(Insika::Error)
    end
  end
end
