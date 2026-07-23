# frozen_string_literal: true

require "spec_helper"
require "insika/tools/a2a_remote" # the wiring loads it lazily; explicit in the test

RSpec.describe Insika::Tools::A2ARemote do
  # fake client: returns the configured result, records the call.
  class FakeClient
    attr_reader :calls

    def initialize(result) = (@result = result; @calls = [])
    def call(url, text, context_id: nil) = (@calls << [url, text]; @result)
  end

  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  def tool(result)
    described_class.new(client: FakeClient.new(result), url: "http://r/a2a",
                        tool_name: "remote_worker", description: "Delega ao worker",
                        event_stream: event_stream)
  end

  it "name/description per instance" do
    t = tool({ text: "x" })
    expect(t.name).to eq("remote_worker")
    expect(t.description).to eq("Delega ao worker")
  end

  it "delegates to the client and returns the text; emits :a2a_call" do
    t = tool({ text: "42", state: "completed", id: "rt1" })
    expect(t.execute(message: "quanto?")).to eq("42")
    ev = events.last
    expect(ev.type).to eq(:a2a_call)
    expect(ev.data).to eq({ agent: "remote_worker", remote_task_id: "rt1", state: "completed" })
  end

  it "remote error -> { error: } to the model (does not raise)" do
    t = tool({ error: "deu ruim", state: "failed", id: nil })
    expect(t.execute(message: "x")).to eq({ error: "deu ruim" })
    expect(events.last.data[:state]).to eq("failed")
  end
end
