# frozen_string_literal: true

require_relative "../../scripts/store_copy"

RSpec.describe "Insika::StoreCopy" do
  it "copies every key of every scope, values intact" do
    from = Insika::Stores::Memory.new
    from.set("sessions", "s1", { "messages" => ["hi"] })
    from.set("config:agents", "a", { "id" => "a" })
    from.set("tasks", "t1", "queued")
    to = Insika::Stores::Memory.new

    expect(Insika::StoreCopy.call(from: from, to: to, batch: 2)).to eq(3)
    expect(to.get("sessions", "s1")).to eq({ "messages" => ["hi"] })
    expect(to.list("config:agents")).to eq(["a"])
    expect(to.get("tasks", "t1")).to eq("queued")
  end
end
