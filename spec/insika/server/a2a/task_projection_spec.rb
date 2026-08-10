# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../lib/insika/server/a2a/task_projection"

RSpec.describe Insika::Server::A2A::TaskProjection do
  FakeTask = Struct.new(:id, :status, :session_id)

  def task(status, id: "t1", session: "s1") = FakeTask.new(id, status, session)

  it "maps each core state to the A2A TaskState" do
    {
      queued: "submitted", running: "working", waiting: "input-required",
      paused: "working", completed: "completed", failed: "failed", cancelled: "canceled"
    }.each do |core, a2a|
      expect(described_class.call(task(core), at: "T")[:status][:state]).to eq(a2a)
    end
  end

  it "unknown state -> 'unknown'" do
    expect(described_class.call(task(:weird), at: "T")[:status][:state]).to eq("unknown")
  end

  it "id/contextId/kind/timestamp and empty lists" do
    a2a = described_class.call(task(:running), at: "2026-01-01T00:00:00Z")
    expect(a2a).to include(id: "t1", contextId: "s1", kind: "task", artifacts: [], history: [])
    expect(a2a[:status][:timestamp]).to eq("2026-01-01T00:00:00Z")
  end

  it "completed carries the content in status.message (TextPart, role agent)" do
    a2a = described_class.call(task(:completed), at: "T", content: "resposta")
    expect(a2a[:status][:message]).to eq({ role: "agent", parts: [{ kind: "text", text: "resposta" }] })
  end

  it "failed carries the error in status.message" do
    a2a = described_class.call(task(:failed), at: "T", error: "boom")
    expect(a2a[:status][:message][:parts].first[:text]).to eq("boom")
  end

  it "non-terminal has no status.message" do
    expect(described_class.call(task(:running), at: "T", content: "x")[:status]).not_to have_key(:message)
  end
end
