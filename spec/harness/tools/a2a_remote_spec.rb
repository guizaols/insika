# frozen_string_literal: true

require "spec_helper"
require "harness/tools/a2a_remote" # o wiring o carrega lazy; explícito no teste

RSpec.describe Harness::Tools::A2ARemote do
  # client fake: devolve o resultado configurado, grava a chamada.
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

  it "name/description por instância" do
    t = tool({ text: "x" })
    expect(t.name).to eq("remote_worker")
    expect(t.description).to eq("Delega ao worker")
  end

  it "delega ao client e devolve o texto; emite :a2a_call" do
    t = tool({ text: "42", state: "completed", id: "rt1" })
    expect(t.execute(message: "quanto?")).to eq("42")
    ev = events.last
    expect(ev.type).to eq(:a2a_call)
    expect(ev.data).to eq({ agent: "remote_worker", remote_task_id: "rt1", state: "completed" })
  end

  it "erro remoto -> { error: } ao modelo (não levanta)" do
    t = tool({ error: "deu ruim", state: "failed", id: nil })
    expect(t.execute(message: "x")).to eq({ error: "deu ruim" })
    expect(events.last.data[:state]).to eq("failed")
  end
end
