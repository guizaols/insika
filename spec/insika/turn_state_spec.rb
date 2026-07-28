# frozen_string_literal: true

require "spec_helper"

# Characterization of TurnState (FOLLOWUP §11 R0). It is MUTABLE on purpose (the
# only exception to the Data types): the Middleware and the tool decorators write
# into it. This spec pins the initializer contract, the defaults, and the mutable
# fields R1 (tool-call baseline) and R4 (per-call correlation) will lean on.
RSpec.describe Insika::TurnState do
  def build(**overrides)
    defaults = {
      task: Struct.new(:id, :session_id).new("t", nil),
      profile: Insika::AgentProfile.build(id: "a", model: "m"),
      turn: 1,
      message: "olá"
    }
    described_class.new(**defaults.merge(overrides))
  end

  describe "#initialize" do
    it "exposes the turn's identity (task/profile/turn/message)" do
      task = Struct.new(:id, :session_id).new("task-1", "sess-1")
      profile = Insika::AgentProfile.build(id: "agente", model: "m")
      state = described_class.new(task: task, profile: profile, turn: 3, message: "oi")

      expect(state.task).to be(task)
      expect(state.profile).to be(profile)
      expect(state.turn).to eq(3)
      expect(state.message).to eq("oi")
    end

    it "capability_names starts as {} (not nil — avoids NoMethodError in the post-Policy merge)" do
      expect(build.capability_names).to eq({})
    end

    it "task/profile/turn are read-only (identity); message is rewritable by the Middleware" do
      state = build
      expect(state).not_to respond_to(:task=)
      expect(state).not_to respond_to(:turn=)

      state.message = "reescrito"
      expect(state.message).to eq("reescrito")
    end
  end

  describe "mutable runtime fields (round-trip)" do
    # Each field that R1/R4/Middleware write: ensures it stays read/write.
    %i[
      context allowed_tools allowed_skills chat session model_selection
      halt_reason halt_response guardrail_block guardrail_flags response_content
      output_filter current_tool_call capability_names tenant turn_context usage
      skip_side_effects requires_approval approval_coordinator actor
    ].each do |field|
      it "#{field} is readable and writable" do
        state = build
        sentinel = Object.new
        state.public_send("#{field}=", sentinel)
        expect(state.public_send(field)).to be(sentinel)
      end
    end

    it "current_tool_call defaults to nil (correlation, filled in before_tool_call)" do
      expect(build.current_tool_call).to be_nil
    end
  end

  # Item 30 / P11a: the per-call correlation is the ONE pair of fields that is not
  # an ivar. `before_tool_call` → `tool.call` → `after_tool_result` run in the same
  # fiber, and tool concurrency gives each call its own — so a shared slot would let
  # calls overwrite each other's identity. Serial behaviour is unchanged.
  describe "per-call correlation is FIBER-scoped" do
    it "keeps one fiber's correlation invisible to another" do
      require "async"
      state = build
      seen = {}

      Sync do |task|
        [["call-A", 0.05], ["call-B", 0.01]].map do |id, settle|
          task.async do
            state.current_tool_call = id
            state.current_tool_name = "tool-#{id}"
            task.sleep(settle) # the other fiber writes while this one waits
            seen[id] = [state.current_tool_call, state.current_tool_name]
          end
        end.each(&:wait)
      end

      expect(seen).to eq("call-A" => ["call-A", "tool-call-A"],
                         "call-B" => ["call-B", "tool-call-B"])
    end

    it "a new turn starts CLEAN even inside a fiber that already holds a correlation" do
      # Fiber storage is inherited by fibers created later, so a subagent child
      # spawned from inside a tool call would otherwise key its own side-effects
      # under the parent's tool_call id.
      require "async"
      inherited = nil

      Sync do |task|
        task.async do
          build.current_tool_call = "parent-call"
          task.async { inherited = build.current_tool_call }.wait # the child turn
        end.wait
      end

      expect(inherited).to be_nil
    end

    it "skip_side_effects defaults to nil (Array(nil) => [] in the envelope; new turn)" do
      expect(build.skip_side_effects).to be_nil
    end
  end
end
