# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::ModelVisibleTraceStore do
  let(:backend) { Insika::Stores::Memory.new }
  subject(:store) { described_class.new(store: backend) }

  def payload(turn = 1, tag = "x")
    Insika::ModelVisible.new(instructions: "sys #{tag}", tools: [], messages: [{ "role" => "user", "content" => "m#{turn}" }])
  end

  describe "#record / #find" do
    it "persists a model-visible payload under the (task, turn, part) key" do
      store.record(task_id: "t1", turn: 3, payload: payload(3))
      found = store.find("t1", turn: 3)
      expect(found).to be_a(Insika::ModelVisible)
      expect(found.instructions).to eq("sys x")
      expect(found.messages).to eq([{ "role" => "user", "content" => "m3" }])
    end

    it "separates part keys — turn vs routing records coexist" do
      store.record(task_id: "t1", turn: 1, payload: payload(1, "turn"))
      store.record(task_id: "t1", turn: 1, part: "routing", payload: payload(1, "route"))
      expect(store.find("t1", turn: 1).instructions).to eq("sys turn")
      expect(store.find("t1", turn: 1, part: "routing").instructions).to eq("sys route")
    end

    it "UPSERTS — a resumed turn re-records its ask in place, never duplicates" do
      store.record(task_id: "t1", turn: 2, payload: payload(2, "first"))
      store.record(task_id: "t1", turn: 2, payload: payload(2, "second"))
      expect(store.for_task("t1").length).to eq(1)
      expect(store.find("t1", turn: 2).instructions).to eq("sys second")
    end

    it "missing key -> nil" do
      expect(store.find("t1", turn: 99)).to be_nil
    end

    it "swallows a raising store (the trace never breaks the turn)" do
      broken = Object.new
      def broken.set(*) = raise("boom")
      store = described_class.new(store: broken)
      expect(store.record(task_id: "t1", turn: 1, payload: payload)).to be_nil
    end
  end

  describe "#for_task" do
    it "returns the records ordered by turn" do
      store.record(task_id: "t1", turn: 1, payload: payload(1))
      store.record(task_id: "t1", turn: 10, payload: payload(10))
      store.record(task_id: "t1", turn: 2, payload: payload(2))
      store.record(task_id: "other", turn: 1, payload: payload(1))
      turns = store.for_task("t1").map { |mv| mv.messages[0]["content"] }
      expect(turns).to eq(%w[m1 m2 m10])
    end

    it "filters by part when asked" do
      store.record(task_id: "t1", turn: 1, payload: payload(1, "turn"))
      store.record(task_id: "t1", turn: 1, part: "routing", payload: payload(1, "route"))
      expect(store.for_task("t1").length).to eq(1)
      expect(store.for_task("t1", part: "routing").length).to eq(1)
    end

    it "[] for a task with no records" do
      expect(store.for_task("nope")).to eq([])
    end
  end

  describe "#purge" do
    it "removes exactly the task's records (turn + routing) and reports the count" do
      store.record(task_id: "t1", turn: 1, payload: payload(1))
      store.record(task_id: "t1", turn: 1, part: "routing", payload: payload(1, "r"))
      store.record(task_id: "t1", turn: 2, payload: payload(2))
      store.record(task_id: "t2", turn: 1, payload: payload(1))
      expect(store.purge("t1")).to eq(3)
      expect(store.for_task("t1")).to eq([])
      expect(store.for_task("t2").length).to eq(1)
    end
  end
end