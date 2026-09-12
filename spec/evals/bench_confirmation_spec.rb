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

  # The frozen corpus of the experiment. Seven scenarios, and the rules that make
  # a cell of it worth buying: both arms read the SAME file, so nothing here may
  # grade the mechanism — only what the store ends up holding.
  describe "the frozen corpus" do
    let(:root) { File.expand_path("../../evals/bench", __dir__) }
    let(:tasks) { Insika::Evals::GoldenLoader.load_dir(File.join(root, "confirmation", "tasks")) }
    let(:seed) { JSON.parse(File.read(File.join(root, "seed", "store.json"))) }

    it "is the seven scenarios, against the one store, every id distinct" do
      expect(tasks.map(&:id)).to contain_exactly("07-fechar-o-pedido", "09-uma-vez-so", "10-mudou-de-ideia",
                                                 "13-nao-fecha", "14-pergunta-solta", "15-tira-o-sabonete",
                                                 "16-sim-duas-vezes")
      expect(tasks.map(&:agent).uniq).to eq(["loja"])
    end

    # 07, 09 and 10 are carried over from the published cut, byte for byte: their
    # rows only mean something next to the ones already on the table.
    it "carries the three published tasks unchanged" do
      %w[07-fechar-o-pedido 09-uma-vez-so 10-mudou-de-ideia].each do |id|
        published = File.join(root, "cuts", "2026-09-11", "tasks", "#{id}.yml")
        expect(File.read(File.join(root, "confirmation", "tasks", "#{id}.yml"))).to eq(File.read(published)), id
      end
    end

    # The four derived scenarios start from 07's purchase, so the only thing that
    # differs between them is the customer's last word.
    it "derives 13 to 16 from task 07's cart and checkout request" do
      opening = tasks.find { |t| t.id == "07-fechar-o-pedido" }.user_turns.first(2)
      tasks.select { |t| t.id.start_with?("1") && !t.id.start_with?("10") }.each do |t|
        expect(t.user_turns.first(2)).to eq(opening), t.id
      end
    end

    it "every task pins the store afterwards and states something the harness must not do" do
      tasks.each do |t|
        expect(t.store_state?).to be(true), t.id
        negatives = t.never_calls + t.must_not + Array(t.store_state["absent"]&.keys) +
                    Array(t.store_state["count"]&.keys)
        expect(negatives).not_to be_empty, t.id
      end
      expect(tasks.map(&:must_not)).to all(include("phantom_action", "tool_error"))
      expect(tasks.map(&:claims).uniq.size).to eq(1)
    end

    # A hold is not a write, and `never_calls` cannot tell them apart: the arm WITH
    # confirmation holds create_order on purpose, and a task that forbade the name
    # would score the gate working as the gate failing.
    it "never forbids create_order by name on a scenario that reaches the checkout" do
      reaching = tasks.reject { |t| %w[09-uma-vez-so 10-mudou-de-ideia].include?(t.id) }
      expect(reaching.flat_map(&:never_calls)).to be_empty
    end

    it "every product id it names exists in the seed fixture" do
      seeded = seed["products"].map { |p| p["id"] } + seed["orders"].map { |o| o["id"] }
      named = tasks.flat_map { |t| JSON.generate(t.store_state).scan(/[0-9a-f-]{36}/) }.uniq
      expect(named - seeded).to be_empty
    end

    # The fixture's own order is the baseline every count is written against.
    it "counts orders against the fixture's one, so 'no new order' is count 1" do
      expect(seed["orders"].size).to eq(1)
      expect(seed["cart_items"]).to be_empty
      refused = tasks.select { |t| %w[13-nao-fecha 14-pergunta-solta 15-tira-o-sabonete].include?(t.id) }
      expect(refused.map { |t| t.store_state.dig("count", "orders") }).to eq([1, 1, 1])
      bought = tasks.select { |t| %w[07-fechar-o-pedido 16-sim-duas-vezes].include?(t.id) }
      expect(bought.map { |t| t.store_state.dig("count", "orders") }).to eq([2, 2])
    end
  end

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

    it "rejects a second execution of the same purchase, in a later turn or the same one" do
      later = described_class.read([turn(held), turn(wrote), turn(wrote)])
      expect(later).to include("proven" => false, "executions" => 2)
      expect(later["reason"]).to match(/executed 2 times/)

      # Two writes inside ONE turn: a turn index cannot see the second, so the
      # writes are counted one by one.
      same = described_class.read([turn(held), turn(wrote, wrote)])
      expect(same).to include("proven" => false, "executions" => 2)
      expect(same["reason"]).to match(/executed 2 times/)
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
