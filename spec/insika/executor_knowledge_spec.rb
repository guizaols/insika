# frozen_string_literal: true

require "spec_helper"

# The terminal hook: after a turn persists, if the profile opted into
# `knowledge.extract` and a store + a usable model are wired, the Executor
# extracts durable concepts from THAT turn. Non-supervised (default in specs)
# dispatches inline — no fiber/Async choreography needed to observe it.
RSpec.describe "Insika::Executor knowledge extraction" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:knowledge_store) { Insika::KnowledgeStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) do
    Insika::AgentProfile.build(id: "acme", model: "m", knowledge: { "extract" => true, "model" => "fake-model" })
  end

  def build_executor(store: knowledge_store)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "acme" => profile },
      session_store: Insika::SessionStore.new(store: backend), task_store: Insika::TaskStore.new(store: backend),
      checkpoint_store: Insika::CheckpointStore.new(store: backend),
      event_stream: event_stream, knowledge_store: store
    )
  end

  def task_for(session_id: "sess-1")
    cmd = Insika::Command.build(:send_message, { agent: "acme", message: "hi" }).to_h
    Insika::TaskStore.new(store: backend).create(command: cmd, session_id: session_id, id: "task-1")
  end

  # A long-enough turn so the cheap-skip gate (KNOWLEDGE_MIN_CHARS) does not
  # eat the fixture — the RFC's own mitigation, exercised separately below.
  def long_messages(extra = "")
    [
      { "role" => "user", "content" => "Qual o prazo de entrega para o CEP 13000-000? #{'x' * 150}" },
      { "role" => "assistant", "content" => "Pedidos para essa faixa de CEP saem do CD de Campinas. #{extra}" }
    ]
  end

  def stub_extractor(result)
    fake = instance_double(Insika::Knowledge::Extractor, extract: result)
    allow(Insika::Knowledge::ExtractorFactory).to receive(:build).and_return(fake)
    fake
  end

  it "writes the extracted concept to the knowledge store and emits :knowledge_learned" do
    stub_extractor(concepts: [{ "name" => "cep-13-campinas", "description" => "d", "type" => "fact", "body" => "b" }],
                   dropped: {}, cost: nil)
    executor = build_executor
    task = task_for

    executor.send(:finalize_knowledge_extraction, task, profile, long_messages)

    stored = knowledge_store.get("acme", "cep-13-campinas")
    expect(stored).to include("provenance: \"observed\"")
    expect(stored).to include("confidence: 0.6")
    expect(event_stream.types).to include(:knowledge_learned)
    learned = event_stream.events.find { |e| e.type == :knowledge_learned }
    expect(learned.data).to eq(name: "cep-13-campinas", type: "fact", agent: "acme")
  end

  it "no-ops without a knowledge store (parity)" do
    executor = build_executor(store: nil)
    expect(Insika::Knowledge::ExtractorFactory).not_to receive(:build)
    executor.send(:finalize_knowledge_extraction, task_for, profile, long_messages)
  end

  it "no-ops when the profile did not opt in" do
    off_profile = Insika::AgentProfile.build(id: "acme", model: "m")
    executor = build_executor
    expect(Insika::Knowledge::ExtractorFactory).not_to receive(:build)
    executor.send(:finalize_knowledge_extraction, task_for, off_profile, long_messages)
  end

  it "skips a trivially short turn without spending a model call" do
    executor = build_executor
    expect(Insika::Knowledge::ExtractorFactory).not_to receive(:build)
    executor.send(:finalize_knowledge_extraction, task_for, profile, [{ "role" => "user", "content" => "oi" }])
  end

  it "no-ops when no model is resolvable (ExtractorFactory returns nil)" do
    allow(Insika::Knowledge::ExtractorFactory).to receive(:build).and_return(nil)
    executor = build_executor
    executor.send(:finalize_knowledge_extraction, task_for, profile, long_messages)
    expect(event_stream.types).not_to include(:knowledge_learned)
  end

  it "a contradicting sighting never overwrites — it emits :knowledge_conflict instead of :knowledge_learned" do
    knowledge_store.write("acme", "cep-13-campinas",
                          Insika::Knowledge::Concept.render(
                            name: "cep-13-campinas", description: "d", type: "fact", body: "b",
                            provenance: "observed", confidence: 0.6, sources: ["sess-0"], occurrences: 1,
                            created_at: "2026-08-01T00:00:00Z", updated_at: "2026-08-01T00:00:00Z"
                          ))
    stub_extractor(concepts: [{ "name" => "cep-13-campinas", "description" => "d", "type" => "fact",
                               "body" => "a totally different claim" }], dropped: {}, cost: nil)
    consolidator = instance_double(Insika::Knowledge::Consolidator, resolve: { verdict: :contradicting })
    allow(Insika::Knowledge::ConsolidatorFactory).to receive(:build).and_return(consolidator)
    executor = build_executor

    executor.send(:finalize_knowledge_extraction, task_for, profile, long_messages)

    stored = knowledge_store.get("acme", "cep-13-campinas")
    expect(stored).to include("## Contradiction")
    expect(stored).to include("confidence: 0.4")
    expect(event_stream.types).not_to include(:knowledge_learned)
    conflict = event_stream.events.find { |e| e.type == :knowledge_conflict }
    expect(conflict.data).to eq(name: "cep-13-campinas", agent: "acme")
  end

  it "swallows an extraction failure — never re-fails an already-committed turn" do
    fake = instance_double(Insika::Knowledge::Extractor)
    allow(fake).to receive(:extract).and_raise(StandardError, "boom")
    allow(Insika::Knowledge::ExtractorFactory).to receive(:build).and_return(fake)
    executor = build_executor

    expect { executor.send(:finalize_knowledge_extraction, task_for, profile, long_messages) }.not_to raise_error
  end
end
