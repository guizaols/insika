# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../../evals/bench/confirmation/proof"

# The confirmation experiment's own data, checked offline: the reader that decides
# whether a cell PROVES the customer's word gated the write. Without it a report
# can call a write confirmed because the reply said so, which is the exact failure
# the experiment exists to measure.
RSpec.describe "the customer-confirmation bench" do
  def turn(*calls) = { "tool_calls" => calls }
  def held = { "name" => "create_order", "status" => "held", "gate" => "confirmation" }
  def wrote = { "name" => "create_order", "status" => "ok" }
  def cart = { "name" => "add_to_cart", "status" => "ok" }

  describe ConfirmationProof do
    it "proves a write held on one turn and executed on a later one" do
      verdict = described_class.read([turn(cart, held), turn(wrote)])
      expect(verdict).to include("proven" => true, "held_turns" => [0], "executed_turns" => [1], "reason" => nil)
    end

    it "rejects a write with no hold on record — an empty call list is not a hold" do
      verdict = described_class.read([turn(cart), turn(wrote)])
      expect(verdict["proven"]).to be(false)
      expect(verdict["reason"]).to match(/no hold on record/)
    end

    it "rejects a write that lands on the same turn as its hold — nobody answered yet" do
      verdict = described_class.read([turn(cart), turn(held, wrote)])
      expect(verdict["proven"]).to be(false)
      expect(verdict["reason"]).to match(/before any hold/)
    end

    it "rejects a second execution of the same purchase" do
      verdict = described_class.read([turn(held), turn(wrote), turn(wrote)])
      expect(verdict["proven"]).to be(false)
      expect(verdict["reason"]).to match(/executed 2 times/)
    end

    it "reads how each hold ended, in order, without turning a decision into a write" do
      confirmed = { "name" => "confirm_pending", "status" => "ok", "gate" => "confirmation",
                    "arguments" => { "pending_id" => "confirm:s1:create_order", "tool" => "create_order" } }
      cancelled = { "name" => "cancel_pending", "status" => "ok", "gate" => "confirmation",
                    "arguments" => { "pending_id" => "confirm:s1:create_order", "tool" => "create_order" } }
      expired = { "name" => "confirmation_expired", "status" => "ok", "gate" => "confirmation",
                  "arguments" => { "pending_id" => "confirm:s1:create_order", "tool" => "create_order" } }

      verdict = described_class.read([turn(held), turn(cancelled), turn(held), turn(wrote, confirmed)])
      expect(verdict["decisions"].map { |d| d["decision"] }).to eq(%w[cancelled confirmed])
      expect(verdict["decisions"].first).to include("turn" => 2, "pending_id" => "confirm:s1:create_order")
      # One write, and it is the store's — the confirmation event beside it is not
      # a second execution.
      expect(verdict["executed_turns"]).to eq([3])
      expect(verdict["proven"]).to be(true)

      held_then_expired = described_class.read([turn(held), turn(expired)])
      expect(held_then_expired["decisions"].map { |d| d["decision"] }).to eq(["expired"])
      expect(held_then_expired).to include("proven" => false, "reason" => "held, never executed")
    end

    it "says nothing was written rather than claiming a proof" do
      expect(described_class.read([turn(cart), turn(held)]))
        .to include("proven" => false, "reason" => "held, never executed")
      expect(described_class.read([turn(cart)]))
        .to include("proven" => false, "reason" => "no create_order and no hold")
    end
  end
end
