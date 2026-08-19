# frozen_string_literal: true

require "spec_helper"

# the Studio's delete on the Artifacts tab — a bus command,
# like every Studio mutation (the Studio never writes a store directly).
RSpec.describe Insika::Commands::DeleteArtifact do
  let(:backend) { Insika::Stores::Memory.new }
  let(:artifact_store) { Insika::ArtifactStore.new(store: backend) }
  let(:stream) { SpyEventStream.new }
  subject(:command) { described_class.new(artifact_store: artifact_store, event_stream: stream) }

  def run(id)
    command.call(Insika::Command.build(:delete_artifact, { id: id }))
  end

  it "deletes the artifact and emits :artifact_deleted with the id" do
    artifact_store.create(tenant: "acme", agent: "a", task_id: "t-1", title: "daily",
                          mime: "text/html", content: "<p>x</p>", id: "a1")
    result = run("a1")
    expect(result[:deleted]).to eq("a1")
    expect(artifact_store.find("a1")).to be_nil
    ev = stream.events.find { |e| e.type == :artifact_deleted }
    expect(ev.data[:id]).to eq("a1")
  end

  it "an unknown id is an idempotent no-op (not an error)" do
    expect(run("nope")[:deleted]).to be_nil
    expect(stream.events).to be_empty
  end

  it "id is required" do
    expect { command.call(Insika::Command.build(:delete_artifact, {})) }
      .to raise_error(Insika::ValidationError, /id is required/)
  end
end