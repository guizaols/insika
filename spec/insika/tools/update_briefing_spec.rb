# frozen_string_literal: true

require "spec_helper"
require "insika/tools/update_briefing" # the Executor loads it lazily; explicit in the test

RSpec.describe Insika::Tools::UpdateBriefing do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }
  let(:task) { Struct.new(:id, :session_id).new("t1", "s1") }
  let(:state) { Insika::TurnState.new(task: task, profile: Insika::AgentProfile.build(id: "a", model: "m"), turn: 1, message: "oi") }

  before { sessions.create(id: "s1") }

  def tool(fields: %w[size budget])
    described_class.new(session_store: sessions, fields: fields,
                        event_stream: event_stream, state: state)
  end

  it "def name = 'update_briefing' (not the one derived from the class)" do
    expect(tool.name).to eq("update_briefing")
  end

  it "persists a valid field+value and emits :briefing_updated with kind/field/value + task meta" do
    result = tool.execute(field: "size", value: "M")

    expect(result[:updated]).to eq("size")
    expect(result[:briefing]["fields"]).to eq("size" => "M")
    expect(sessions.find("s1").briefing["fields"]).to eq("size" => "M")

    ev = events.last
    expect(ev.type).to eq(:briefing_updated)
    expect(ev.data).to eq(kind: "field", field: "size", value: "M")
    expect(ev.meta).to eq(task_id: "t1", session_id: "s1")
  end

  it "an undeclared field returns an ENVELOPE error and NEVER persists (E2)" do
    sessions.update_briefing("s1", field: "size", value: "M")

    result = tool.execute(field: "vibe", value: "x")

    expect(result).to eq({ error: "unknown field 'vibe'; declared: size, budget" })
    expect(sessions.find("s1").briefing["fields"]).to eq("size" => "M")
    expect(events).to be_empty
  end

  it "a blank value removes the key (absence = not yet asked)" do
    sessions.update_briefing("s1", field: "size", value: "M")

    result = tool.execute(field: "size", value: "")

    expect(result[:briefing]["fields"]).to eq({})
    expect(sessions.find("s1").briefing["fields"]).to eq({})
  end

  it "the description lists every declared name" do
    desc = tool(fields: %w[size budget delivery_day]).description
    expect(desc).to include("size", "budget", "delivery_day")
    expect(desc).not_to include("vibe")
  end

  it "the schema carries the declared names as the `field` enum " do
    schema = tool(fields: %w[size budget delivery_day]).params_schema
    expect(schema.dig("properties", "field", "enum")).to eq(%w[size budget delivery_day])
  end

  it "no fields declared -> no enum and no empty 'one of: .' placeholder (review trap)" do
    schema = tool(fields: []).params_schema
    expect(schema.dig("properties", "field")).not_to have_key("enum")
    expect(tool(fields: []).description).not_to include("one of:")
  end

  it "no session on the task -> envelope error, nothing persisted" do
    st = Insika::TurnState.new(
      task: Struct.new(:id, :session_id).new("t2", nil),
      profile: Insika::AgentProfile.build(id: "a", model: "m"), turn: 1, message: "oi"
    )
    t = described_class.new(session_store: sessions, fields: %w[size],
                            event_stream: event_stream, state: st)
    expect(t.execute(field: "size", value: "M")).to eq({ error: "no session to brief" })
    expect(events).to be_empty
  end

  it "a missing session record -> envelope error (the model can retry later)" do
    t = described_class.new(session_store: sessions, fields: %w[size],
                            event_stream: event_stream,
                            state: Insika::TurnState.new(
                              task: Struct.new(:id, :session_id).new("t3", "nope"),
                              profile: Insika::AgentProfile.build(id: "a", model: "m"),
                              turn: 1, message: "oi"
                            ))
    expect(t.execute(field: "size", value: "M")).to eq({ error: "session not found" })
  end

  describe Insika::Tools::UpdateBriefing::SetNextStep do
    let(:state) { Insika::TurnState.new(task: task, profile: Insika::AgentProfile.build(id: "a", model: "m"), turn: 1, message: "oi") }

    def tool
      described_class.new(session_store: sessions, event_stream: event_stream, state: state)
    end

    it "def name = 'set_next_step'" do
      expect(tool.name).to eq("set_next_step")
    end

    it "records the agreed next step and emits :briefing_updated kind next_step" do
      result = tool.execute(text: "send the payment link tomorrow at 10")

      expect(result[:next_step]).to eq("send the payment link tomorrow at 10")
      expect(sessions.find("s1").briefing["next_step"]).to eq("send the payment link tomorrow at 10")

      ev = events.last
      expect(ev.type).to eq(:briefing_updated)
      expect(ev.data).to eq(kind: "next_step", field: nil, value: "send the payment link tomorrow at 10")
      expect(ev.meta).to eq(task_id: "t1", session_id: "s1")
    end

    it "a blank text clears to nil" do
      sessions.set_next_step("s1", text: "send the payment link")
      result = tool.execute(text: "")
      expect(result[:next_step]).to be_nil
      expect(sessions.find("s1").briefing["next_step"]).to be_nil
    end

    it "no session -> envelope error" do
      st = Insika::TurnState.new(
        task: Struct.new(:id, :session_id).new("t4", nil),
        profile: Insika::AgentProfile.build(id: "a", model: "m"), turn: 1, message: "oi"
      )
      t = described_class.new(session_store: sessions, event_stream: event_stream, state: st)
      expect(t.execute(text: "send link")).to eq({ error: "no session to brief" })
    end
  end
end