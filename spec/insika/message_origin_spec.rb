# frozen_string_literal: true

require "spec_helper"
require "async"

# WHO produced a transcript message — the field `role` cannot carry.
#
# The first refinement run over real traffic reported `repetition ×219` on one agent,
# every one of them the engine reading its own injected fragment back and calling it a
# customer repeating themselves (PR #133). That was filtered by a regex on the leading
# tag, labelled in the code as a heuristic standing in for a structural marker. This is
# the marker.
RSpec.describe Insika::MessageOrigin do
  describe "the closed set" do
    it "accepts a declared origin" do
      expect(described_class.parse!("engine")).to eq("engine")
      expect(described_class.parse!(:OPERATOR)).to eq("operator")
    end

    it "reads blank as absent — a turn that declares nothing is the common case" do
      expect(described_class.parse!(nil)).to be_nil
      expect(described_class.parse!("  ")).to be_nil
    end

    # A marker that silently means "unmarked" is worse than none: it looks like the
    # filtering is on.
    it "REFUSES an unknown value instead of storing it" do
      expect { described_class.parse!("enigne") }
        .to raise_error(Insika::ValidationError, /unknown message origin.*engine/m)
    end

    it "accepts the   closed value 'scheduled'" do
      expect(described_class.parse!("scheduled")).to eq("scheduled")
      expect(described_class::SCHEDULED).to eq("scheduled")
      expect(described_class::ALL).to include("scheduled")
    end
  end

  describe "reading a message" do
    def msg(role, origin = nil)
      h = { "role" => role, "content" => "x" }
      origin ? h.merge("origin" => origin) : h
    end

    it "an ABSENT origin reads as the natural producer for the role" do
      # Every transcript written before this field existed, which is all of them.
      expect(described_class).to be_customer(msg("user"))
      expect(described_class).to be_agent(msg("assistant"))
    end

    it "the engine's own 'user' turn is not the customer" do
      expect(described_class).not_to be_customer(msg("user", "engine"))
    end

    it "a scheduled follow-up kick is never read as the customer (the #133 discipline)" do
      expect(described_class).not_to be_customer(msg("user", "scheduled"))
    end

    it "a guardrail's reply and a human operator's are not the agent" do
      expect(described_class).not_to be_agent(msg("assistant", "engine"))
      expect(described_class).not_to be_agent(msg("assistant", "operator"))
    end
  end
end

# The engine stamping what it truthfully knows, end to end through a real turn.
RSpec.describe "message origin in the transcript" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  def build_executor(**over)
    Insika::Executor.new(**{
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    }.merge(over))
  end

  def run_turn(payload)
    executor = build_executor
    chat = FakeChat.new
    chat.final_content = "claro!"
    allow(executor).to receive(:create_chat).and_return(chat)
    session_store.create(id: "s1")
    task = task_store.create(
      command: Insika::Command.build(:send_message, { agent: "sales" }.merge(payload)).to_h,
      session_id: "s1", id: "t"
    )
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
    session_store.find("s1").messages
  end

  it "an ordinary turn declares NOTHING — the shape is unchanged" do
    messages = run_turn(message: "quanto custa?")

    expect(messages.map { |m| m["role"] }).to eq(%w[user assistant])
    expect(messages.map(&:keys).flatten.uniq).not_to include("origin")
  end

  it "a declared origin lands on the message it describes, and only that one" do
    messages = run_turn(message: "<memoria>…</memoria> quanto custa?", origin: "engine")

    expect(messages[0]["origin"]).to eq("engine")   # the composed input
    expect(messages[1]).not_to have_key("origin")   # the model's reply is still the model's
  end

  #   (closing the deliver loop): the FollowupEngine's synthetic
  # command flows through the FULL pipeline like any turn — the task runs, the
  # kick text is stamped origin "scheduled", so a refinement read can never
  # mistake the engine for the customer (the #133 discipline).
  it "a scheduled_followup command runs through the pipeline stamped 'scheduled'" do
    messages = run_turn(message: "the follow-up kick text", origin: "scheduled")

    expect(messages.map { |m| m["role"] }).to eq(%w[user assistant])
    expect(messages[0]["origin"]).to eq("scheduled")
    expect(messages[0]["content"]).to eq("the follow-up kick text")
    expect(Insika::MessageOrigin).not_to be_customer(messages[0])
  end
end
