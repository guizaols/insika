# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::TaskStore do
  # Against Memory; parity with SQLite guaranteed by the contract
  # suite + a SQLite ":memory:" smoke test.
  subject(:tasks) { described_class.new(store: backend) }

  let(:backend) { Insika::Stores::Memory.new }
  let(:command) { { type: "send_message", payload: {}, meta: {} } }

  describe "full transition matrix" do
    # Valid set transcribed from the table in (12 pairs ✓).
    valid = {
      queued: %i[running cancelled failed], # failed:-03 (failure starting while queued)
      running: %i[waiting paused completed failed cancelled],
      waiting: %i[running cancelled failed],
      paused: %i[running cancelled]
    }
    valid.default = []

    # Prepares a task in the source state by writing the record directly to the
    # backend (acceptable in a store test) — avoids depending on valid paths.
    def seed_in_state(state)
      id = "t-#{state}"
      now = "2020-01-01T00:00:00Z"
      backend.set("tasks", "task:#{id}", {
                    "id" => id, "status" => state.to_s, "command" => {},
                    "session_id" => nil, "executions" => [],
                    "mailbox_state" => { "pending" => [] },
                    "created_at" => now, "updated_at" => now
                  })
      id
    end

    described_class::STATUSES.each do |from|
      described_class::STATUSES.each do |to|
        if valid[from].include?(to)
          it "#{from} -> #{to} transitions" do
            id = seed_in_state(from)
            expect(tasks.transition(id, to: to).status).to eq(to)
          end
        else
          it "#{from} -> #{to} raises ArgumentError" do
            id = seed_in_state(from)
            expect { tasks.transition(id, to: to) }.to raise_error(ArgumentError)
          end
        end
      end
    end

    it "covers the 49 pairs (13 valid, 36 invalid)" do
      valid_count = described_class::STATUSES.sum { |s| valid[s].size }
      expect(valid_count).to eq(13) # 1: queued->failed (03)
      expect(described_class::STATUSES.size**2).to eq(49)
    end
  end

  describe "#create" do
    it "returns Task with defaults" do
      task = tasks.create(command: command)

      expect(task.status).to eq(:queued)
      expect(task.executions).to eq([])
      expect(task.mailbox_state).to eq({ "pending" => [] })
      expect { Time.iso8601(task.created_at) }.not_to raise_error
    end

    it "raises ArgumentError on duplicate id" do
      tasks.create(command: command, id: "x")

      expect { tasks.create(command: command, id: "x") }.to raise_error(ArgumentError)
    end

    it "normalizes command Hash with symbols to string keys" do
      task = tasks.create(command: { type: :send_message, payload: { a: 1 } })

      expect(task.command).to eq({ "type" => "send_message", "payload" => { "a" => 1 } })
    end

    it "accepts an object that responds to to_h (e.g. future Insika::Command)" do
      command_like = Data.define(:type, :payload, :meta).new(
        type: "send_message", payload: {}, meta: {}
      )
      task = tasks.create(command: command_like)

      expect(task.command).to eq({ "type" => "send_message", "payload" => {}, "meta" => {} })
    end
  end


  describe "#begin_execution / #finish_execution" do
    let(:id) { tasks.create(command: command, id: "t").id }

    it "numbers attempts and preserves history (append-only)" do
      tasks.begin_execution(id)
      tasks.finish_execution(id, outcome: "failed")
      task = tasks.begin_execution(id)

      expect(task.executions.map(&:attempt)).to eq([1, 2])
      expect(task.executions.first.outcome).to eq("failed")
      expect(task.executions.first.finished_at).not_to be_nil
    end

    it "begin with an open Execution raises ArgumentError" do
      tasks.begin_execution(id)

      expect { tasks.begin_execution(id) }.to raise_error(ArgumentError)
    end

    it "finish closes the current one without touching status" do
      tasks.begin_execution(id)
      task = tasks.finish_execution(id, outcome: "completed")

      expect(task.executions.last.finished_at).not_to be_nil
      expect(task.executions.last.outcome).to eq("completed")
      expect(task.status).to eq(:queued)
    end

    it "finish without an open Execution raises ArgumentError" do
      expect { tasks.finish_execution(id, outcome: "x") }.to raise_error(ArgumentError)
    end
  end

  describe "#transition with error:" do
    let(:id) { tasks.create(command: command, id: "t").id }
    let(:err) { { class: "RuntimeError", message: "boom", stage: :provider } }

    it "closes the open Execution recording the error (string keys)" do
      tasks.begin_execution(id)
      tasks.transition(id, to: :running)
      task = tasks.transition(id, to: :failed, error: err)

      execution = task.executions.last
      expect(execution.outcome).to eq("failed")
      expect(execution.finished_at).not_to be_nil
      expect(execution.error).to eq(
        { "class" => "RuntimeError", "message" => "boom", "stage" => "provider" }
      )
    end

    it "without an open Execution transitions and ignores error: (does not raise)" do
      task = tasks.transition(id, to: :cancelled, error: err)

      expect(task.status).to eq(:cancelled)
      expect(task.executions).to eq([])
    end

    it "retry: a new begin after transition(:failed, error:) opens attempt 2 and preserves the 1st (edge case 7)" do
      tasks.begin_execution(id)
      tasks.transition(id, to: :running)
      tasks.transition(id, to: :failed, error: err) # closes Execution 1 with the error
      task = tasks.begin_execution(id) # retry reopens a new attempt (does not validate status)

      expect(task.executions.map(&:attempt)).to eq([1, 2])
      first = task.executions.first
      expect(first.finished_at).not_to be_nil
      expect(first.outcome).to eq("failed")
      expect(first.error).to include("message" => "boom")
      expect(task.executions.last.finished_at).to be_nil # the 2nd is open
    end
  end

  describe "#running_or_interrupted" do
    it "returns only tasks in running/waiting/paused" do
      # covers the 7 states, reaching each via a valid path
      tasks.create(command: command, id: "q") # queued
      tasks.transition(tasks.create(command: command, id: "r").id, to: :running)
      w = tasks.create(command: command, id: "w").id
      tasks.transition(w, to: :running)
      tasks.transition(w, to: :waiting)
      p = tasks.create(command: command, id: "p").id
      tasks.transition(p, to: :running)
      tasks.transition(p, to: :paused)
      tasks.transition(tasks.create(command: command, id: "c").id, to: :cancelled)
      done = tasks.create(command: command, id: "d").id
      tasks.transition(done, to: :running)
      tasks.transition(done, to: :completed)

      expect(tasks.running_or_interrupted.map(&:id)).to contain_exactly("r", "w", "p")
    end

    it "returns [] when there are no tasks" do
      expect(tasks.running_or_interrupted).to eq([])
    end
  end

  describe "type boundary and queries" do
    it "exposes status as Symbol after find" do
      tasks.create(command: command, id: "t")

      expect(tasks.find("t").status).to eq(:queued)
    end

    it "find nonexistent -> nil" do
      expect(tasks.find("nope")).to be_nil
    end

    it "each_id: ids without prefix and Enumerator without a block" do
      %w[a b c].each { |id| tasks.create(command: command, id: id) }

      expect(tasks.each_id.to_a).to contain_exactly("a", "b", "c")
      expect(tasks.each_id).to be_a(Enumerator)
    end
  end

  describe "NotFoundError on nonexistent id" do
    it "transition" do
      expect { tasks.transition("nope", to: :running) }.to raise_error(Insika::NotFoundError)
    end

    it "begin_execution" do
      expect { tasks.begin_execution("nope") }.to raise_error(Insika::NotFoundError)
    end

    it "finish_execution" do
      expect { tasks.finish_execution("nope", outcome: "x") }.to raise_error(Insika::NotFoundError)
    end
  end

  describe "backend error propagation" do
    it "lets StoreError propagate without re-wrapping" do
      # non-JSONable command forces StoreError on write; the TaskStore does not
      # capture/re-wrap.
      expect { tasks.create(command: { obj: Object.new }) }
        .to raise_error(Insika::StoreError)
    end
  end

  describe "#append_message (collect)" do
    let(:command) { { type: "send_message", payload: { "message" => "oi" }, meta: {} } }

    it "joins fragments onto a queued task's message" do
      id = tasks.create(command: command, id: "t").id

      tasks.append_message(id, "queria o pedido")
      task = tasks.append_message(id, "1234567")

      expect(task.command["payload"]["message"]).to eq("oi\nqueria o pedido\n1234567")
    end

    it "seeds the message when the task had none" do
      id = tasks.create(command: { type: "send_message", payload: {}, meta: {} }, id: "t").id

      expect(tasks.append_message(id, "oi").command["payload"]["message"]).to eq("oi")
    end

    it "REFUSES once the task left :queued — its message is already in flight" do
      id = tasks.create(command: command, id: "t").id
      tasks.transition(id, to: :running)

      expect { tasks.append_message(id, "tarde demais") }
        .to raise_error(ArgumentError, /not queued/)
      expect(tasks.find(id).command["payload"]["message"]).to eq("oi")
    end

    it "a blank fragment is a no-op, not a stray separator" do
      id = tasks.create(command: command, id: "t").id

      expect(tasks.append_message(id, "   ").command["payload"]["message"]).to eq("oi")
    end

    it "raises NotFoundError for an unknown task" do
      expect { tasks.append_message("nope", "x") }.to raise_error(Insika::NotFoundError)
    end
  end

  describe "timing on the task record " do
    it "is nil for a task written before the field existed" do
      id = tasks.create(command: command, id: "t").id
      expect(tasks.find(id).timing).to be_nil
    end

    it "record_timing writes the string-keyed hash and find reads it back" do
      id = tasks.create(command: command, id: "t").id

      tasks.record_timing(id, { first_balloon_ms: 812.5, prep_ms: 3.0 })
      expect(tasks.find(id).timing).to eq("first_balloon_ms" => 812.5, "prep_ms" => 3.0)
    end

    it "raises NotFoundError for an unknown task" do
      expect { tasks.record_timing("nope", {}) }.to raise_error(Insika::NotFoundError)
    end
  end

  describe "smoke against Stores::SQLite ':memory:'" do
    it "create->transition->begin->finish flow identical to Memory" do
      require "sqlite3"
      sqlite = Insika::Stores::SQLite.new(path: ":memory:")
      store = described_class.new(store: sqlite)

      id = store.create(command: command, id: "t").id
      store.begin_execution(id)
      store.transition(id, to: :running)
      task = store.finish_execution(id, outcome: "completed")

      expect(task.status).to eq(:running)
      expect(task.executions.last.outcome).to eq("completed")
    ensure
      sqlite&.close
    end
  end
end
