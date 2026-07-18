# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::CheckpointStore do
  # Against Memory (real rollback, task 03) + SQLite ":memory:" smoke (doc 02 §7).
  subject(:checkpoints) { described_class.new(store: backend) }

  let(:backend) { Harness::Stores::Memory.new }

  # Builds a complete Checkpoint for turn n.
  def checkpoint(task_id: "t", turn: 1, side_effects: [], messages: nil)
    Harness::Checkpoint.new(
      task_id: task_id,
      turn: turn,
      session_id: "s-1",
      agent_id: "sales",
      messages: messages || [{ "role" => "user", "content" => "oi" }],
      completed_side_effects: side_effects,
      created_at: nil
    )
  end

  describe "#save / #find round-trip" do
    it "returns identical fields, Integer turn and string keys in messages" do
      saved = checkpoints.save(checkpoint(turn: 1, messages: [{ role: :user, content: "oi" }]))
      found = checkpoints.find("t", turn: 1)

      expect(found.turn).to be_a(Integer).and eq(1)
      expect(found.session_id).to eq("s-1")
      expect(found.agent_id).to eq("sales")
      expect(found.messages).to eq([{ "role" => "user", "content" => "oi" }])
      expect(found.created_at).to eq(saved.created_at)
      expect { Time.iso8601(found.created_at) }.not_to raise_error
    end

    it "stamps created_at when absent in the received Checkpoint" do
      saved = checkpoints.save(checkpoint(turn: 1))

      expect { Time.iso8601(saved.created_at) }.not_to raise_error
    end
  end

  describe "turn monotonicity" do
    before { checkpoints.save(checkpoint(turn: 2)) }

    it "rejects save of a repeated turn" do
      expect { checkpoints.save(checkpoint(turn: 2)) }.to raise_error(ArgumentError)
    end

    it "rejects save of a lower turn" do
      expect { checkpoints.save(checkpoint(turn: 1)) }.to raise_error(ArgumentError)
    end

    it "writes nothing when rejecting (transaction)" do
      expect { checkpoints.save(checkpoint(turn: 1)) }.to raise_error(ArgumentError)
      expect(checkpoints.latest("t").turn).to eq(2)
    end
  end

  describe "#latest" do
    it "returns the highest turn (sequential)" do
      [1, 2, 3].each { |n| checkpoints.save(checkpoint(turn: n)) }

      expect(checkpoints.latest("t").turn).to eq(3)
    end

    it "returns the highest turn with sparse turns (3, 7, 12)" do
      [3, 7, 12].each { |n| checkpoints.save(checkpoint(turn: n)) }

      expect(checkpoints.latest("t").turn).to eq(12)
    end

    it "orders numerically with turn >= 10 (10 > 9, not lexicographic)" do
      checkpoints.save(checkpoint(turn: 9))
      checkpoints.save(checkpoint(turn: 10))

      expect(checkpoints.latest("t").turn).to eq(10)
    end

    it "returns nil for a task without a checkpoint" do
      expect(checkpoints.latest("nope")).to be_nil
      expect(checkpoints.find("nope", turn: 1)).to be_nil
    end
  end

  describe "side-effects" do
    it "record_side_effect is idempotent" do
      checkpoints.record_side_effect("t", turn: 1, tool_call_id: "call_a")
      checkpoints.record_side_effect("t", turn: 1, tool_call_id: "call_a")

      expect(checkpoints.side_effects("t", turn: 1)).to eq(["call_a"])
    end

    it "side_effects empty when nothing recorded" do
      expect(checkpoints.side_effects("t", turn: 1)).to eq([])
    end

    it "side_effects = standalone key ∪ checkpoint's completed_side_effects" do
      checkpoints.record_side_effect("t", turn: 5, tool_call_id: "call_spill")
      # writes the turn 5 checkpoint with an id already consolidated into it (turn 5
      # without its own standalone absorbed — the turn 4 one is absorbed on the turn 5 save)
      checkpoints.save(checkpoint(turn: 5, side_effects: ["call_cp"]))

      expect(checkpoints.side_effects("t", turn: 5)).to contain_exactly("call_spill", "call_cp")
    end
  end

  describe "consolidation on save (turn n's standalone key absorbed on the turn n+1 save)" do
    it "includes the standalone's ids and deletes the standalone key from the backend" do
      checkpoints.record_side_effect("t", turn: 3, tool_call_id: "call_x")
      saved = checkpoints.save(checkpoint(turn: 4))

      expect(saved.completed_side_effects).to include("call_x")
      expect(backend.get("checkpoints", "sideeffects:t:turn:3")).to be_nil
    end

    it "unions with the ids that already came in the Checkpoint" do
      checkpoints.record_side_effect("t", turn: 3, tool_call_id: "call_spill")
      saved = checkpoints.save(checkpoint(turn: 4, side_effects: ["call_cp"]))

      expect(saved.completed_side_effects).to contain_exactly("call_spill", "call_cp")
    end

    it "consolidates with [] when the turn had no side-effects" do
      saved = checkpoints.save(checkpoint(turn: 1, side_effects: ["call_only_cp"]))

      expect(saved.completed_side_effects).to eq(["call_only_cp"])
    end
  end

  describe "crash-consistency (D4, doc 02 §7)" do
    # Backend that delegates to Memory but whose `delete` raises — the exception occurs
    # INSIDE the save transaction, AFTER the new checkpoint has already been
    # written (set). The real rollback (task 03) must undo the set and preserve the
    # standalone key.
    let(:faulty) do
      Class.new do
        attr_reader :sets

        def initialize(inner)
          @inner = inner
          @sets = 0
        end

        def get(*a) = @inner.get(*a)

        def set(*a)
          @sets += 1
          @inner.set(*a)
        end

        def list(*a) = @inner.list(*a)
        def transaction(&blk) = @inner.transaction(&blk)
        def delete(*) = raise Harness::StoreError, "simulated failure in delete"
      end.new(backend)
    end

    it "an exception mid-save leaves the previous checkpoint intact and the standalone preserved" do
      store = described_class.new(store: faulty)
      # turn 3 already committed (via clean backend, without going through the faulty delete)
      described_class.new(store: backend).save(checkpoint(turn: 3))
      backend.set("checkpoints", "sideeffects:t:turn:3", ["call_pending"])

      expect { store.save(checkpoint(turn: 4)) }.to raise_error(Harness::StoreError)

      # load-bearing precondition: the turn 4 set WAS applied before the delete
      # raised — only then does "latest goes back to 3" prove a real rollback (otherwise
      # it would be a false-green because the write never happened).
      expect(faulty.sets).to eq(1)
      # latest goes back to turn 3 (the turn 4 set was reverted)
      expect(checkpoints.latest("t").turn).to eq(3)
      expect(checkpoints.find("t", turn: 4)).to be_nil
      # the standalone key was not absorbed/deleted
      expect(backend.get("checkpoints", "sideeffects:t:turn:3")).to eq(["call_pending"])
    end
  end

  describe "#prune" do
    it "keep: 1 preserves only the highest turn" do
      (1..4).each { |n| checkpoints.save(checkpoint(turn: n)) }
      checkpoints.prune("t", keep: 1)

      expect(checkpoints.latest("t").turn).to eq(4)
      expect([1, 2, 3].map { |n| checkpoints.find("t", turn: n) }).to all(be_nil)
    end

    it "keep: 2 preserves the two highest turns" do
      (1..4).each { |n| checkpoints.save(checkpoint(turn: n)) }
      checkpoints.prune("t", keep: 2)

      expect(checkpoints.find("t", turn: 3)).not_to be_nil
      expect(checkpoints.find("t", turn: 4)).not_to be_nil
      expect(checkpoints.find("t", turn: 2)).to be_nil
    end

    it "is a no-op with fewer checkpoints than keep" do
      checkpoints.save(checkpoint(turn: 1))
      checkpoints.prune("t", keep: 1)

      expect(checkpoints.find("t", turn: 1)).not_to be_nil
    end

    it "cleans standalone keys of turns before the lowest kept" do
      (1..3).each { |n| checkpoints.save(checkpoint(turn: n)) }
      backend.set("checkpoints", "sideeffects:t:turn:1", ["lixo"])
      checkpoints.prune("t", keep: 1) # keeps only turn 3

      expect(backend.get("checkpoints", "sideeffects:t:turn:1")).to be_nil
    end
  end

  describe "isolation between tasks" do
    it "checkpoints and standalones of task_a don't affect task_b" do
      checkpoints.save(checkpoint(task_id: "a", turn: 5))
      checkpoints.record_side_effect("a", turn: 5, tool_call_id: "call_a")
      checkpoints.save(checkpoint(task_id: "b", turn: 1))

      expect(checkpoints.latest("b").turn).to eq(1)
      expect(checkpoints.side_effects("b", turn: 5)).to eq([])

      checkpoints.prune("a", keep: 1)
      expect(checkpoints.latest("b").turn).to eq(1) # prune of "a" didn't touch "b"
    end
  end

  describe "smoke against Stores::SQLite ':memory:'" do
    it "save->latest->record->save->prune identical to Memory" do
      require "sqlite3"
      sqlite = Harness::Stores::SQLite.new(path: ":memory:")
      store = described_class.new(store: sqlite)

      store.save(checkpoint(turn: 1))
      store.record_side_effect("t", turn: 1, tool_call_id: "call_x")
      saved = store.save(checkpoint(turn: 2))

      expect(store.latest("t").turn).to eq(2)
      expect(saved.completed_side_effects).to include("call_x")

      store.prune("t", keep: 1)
      expect(store.find("t", turn: 1)).to be_nil
    ensure
      sqlite&.close
    end
  end
end
