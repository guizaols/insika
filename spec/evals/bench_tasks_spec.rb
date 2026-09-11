# frozen_string_literal: true

require "spec_helper"
require "json"

# The bench corpus itself, checked as data. These are not tests of the graders (that
# is assertions_spec) — they are the authoring rules that make a bench task worth
# running, enforced so a typo cannot quietly produce a task nothing can fail.
RSpec.describe "the cross-harness bench tasks" do
  let(:root) { File.expand_path("../../evals/bench", __dir__) }
  let(:tasks) { Insika::Evals::GoldenLoader.load_dir(File.join(root, "tasks")) }
  let(:seed) { JSON.parse(File.read(File.join(root, "seed", "store.json"))) }

  it "is twelve tasks against one store, every id distinct" do
    expect(tasks.size).to eq(12)
    expect(tasks.map(&:id).uniq.size).to eq(12)
    expect(tasks.map(&:agent).uniq).to eq(["loja"])
  end

  # Every positive has a negative — the rule the corpus already follows. Without one
  # a task rewards a harness for doing the thing and says nothing about what it must
  # not do, which is where every expensive commerce failure lives.
  it "every task states something the harness must NOT do" do
    tasks.each do |t|
      negatives = t.never_calls + t.reply_omits + t.must_not + t.blocked_gates +
                  Array(t.store_state["absent"]&.keys) + Array(t.store_state["count"]&.keys)
      expect(negatives).not_to be_empty, "#{t.id} has no negative grader"
    end
  end

  # One store, one vocabulary: the words a reply uses to claim a mutation are the
  # store's, copied into every task so the engine never has to know Portuguese. A
  # task whose copy drifted would grade the same reply differently from its siblings.
  it "every task checks for phantom actions with the same claims map" do
    expect(tasks.map(&:must_not)).to all(include("phantom_action"))
    expect(tasks.map(&:claims).uniq.size).to eq(1)
    expect(tasks.first.claims.keys).to contain_exactly("add_to_cart", "remove_from_cart", "create_order")
  end

  # A bench task that does not look at the store is a golden case in the wrong folder.
  it "every task pins what the store looks like afterwards" do
    expect(tasks.reject(&:store_state?)).to be_empty
  end

  # A product id nobody seeded can never match a row, so the task would fail (or,
  # under `absent:`, pass) for a reason that has nothing to do with the harness.
  it "every product id a task names exists in the seed fixture" do
    seeded = seed["products"].map { |p| p["id"] } + seed["orders"].map { |o| o["id"] }
    named = tasks.flat_map { |t| JSON.generate(t.store_state).scan(/[0-9a-f-]{36}/) }.uniq
    expect(named - seeded).to be_empty
  end

  # A task typing an order number the fixture does not carry fails on the store, not
  # on the harness — and it looks exactly like a harness that could not read an order.
  # This is how an anonymised fixture broke a task nobody thought it touched.
  it "every order number a customer types exists in the seed fixture" do
    seeded = seed["orders"].map { |o| o["order_number"] }
    typed = tasks.flat_map { |t| t.user_turns.join(" ").scan(/\b[A-Z]{2,}-\d+\b/) }.uniq
    expect(typed - seeded).to be_empty
  end

  it "the fixture starts with one order and an empty cart, which is what the tasks assume" do
    expect(seed["orders"].size).to eq(1)
    expect(seed["cart_items"]).to be_empty
    # No promotion and no voucher: the coupon task is only honest if the store really
    # has none, and the real store has none.
    expect(seed["promotions"]).to be_empty
    expect(seed["vouchers"]).to be_empty
  end
end
