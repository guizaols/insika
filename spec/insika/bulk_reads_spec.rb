# frozen_string_literal: true

# Reading every session or task used to cost one store read per record (list,
# then find each). On a networked backend that is one round trip per record;
# `all` reads them in one call.
RSpec.describe "bulk reads" do
  let(:backend) { Insika::Stores::Memory.new }

  it "SessionStore#all returns every session from one bulk read" do
    sessions = Insika::SessionStore.new(store: backend)
    sessions.create(id: "s1")
    sessions.create(id: "s2")
    allow(backend).to receive(:get).and_call_original
    allow(backend).to receive(:entries).and_call_original

    expect(sessions.all.map(&:id)).to contain_exactly("s1", "s2")
    expect(backend).to have_received(:entries).once
  end

  it "TaskStore#all returns every task from one bulk read" do
    tasks = Insika::TaskStore.new(store: backend)
    a = tasks.create(command: { type: "x", payload: {}, meta: {} })
    b = tasks.create(command: { type: "x", payload: {}, meta: {} })
    allow(backend).to receive(:entries).and_call_original

    expect(tasks.all.map(&:id)).to contain_exactly(a.id, b.id)
    expect(backend).to have_received(:entries).once
  end
end
