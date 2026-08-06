# frozen_string_literal: true

require "spec_helper"

# The publishing rule in isolation (P19). The Executor specs prove the behaviour
# end to end; this file pins the decisions the pipeline hides — which messages a
# boundary is even about, and how the redactor's retained tail is accounted for.
RSpec.describe Insika::TurnOutput do
  let(:emitted) { [] }
  let(:emit) { ->(type, data) { emitted << [type, data[:delta]] } }

  # A completed message as `after_message` delivers it.
  def message(role: "assistant", content: nil, tool_calls: nil)
    Struct.new(:role, :content, :tool_calls) do
      def tool_call? = !(tool_calls.nil? || tool_calls.empty?)
    end.new(role, content, tool_calls)
  end

  def build(filter: nil) = described_class.new(filter: filter, emit: emit)

  describe "the message that ends the turn" do
    it "becomes the candidate answer — and nothing is published yet" do
      output = build
      output.push("Achei três opções.")
      output.message_ended(message)

      expect(output.candidate).to eq("Achei três opções.")
      # The :agent after-hook still gets to replace the response, so publishing is
      # the Executor's call, at the end of the stage.
      expect(emitted.map(&:first)).to eq([:intermediate])
    end
  end

  describe "a message that also called a tool" do
    it "is never the answer, however much it said" do
      output = build
      output.push("Deixa eu buscar isso pra você.")
      output.message_ended(message(tool_calls: { "c1" => "search" }))

      expect(output.candidate).to be_nil
      expect(output.halt_text).to eq("Deixa eu buscar isso pra você.")
    end

    it "does not bleed into the next message" do
      output = build
      output.push("Deixa eu buscar.")
      output.message_ended(message(tool_calls: { "c1" => "search" }))
      output.push("Achei!")
      output.message_ended(message)

      expect(output.candidate).to eq("Achei!")
    end
  end

  describe "the gem's other message roles" do
    it "ignores a tool result — it is bookkeeping, not something the model said" do
      output = build
      output.push("Deixa eu buscar.")
      output.message_ended(message(role: "tool", content: "[]"))

      expect(output.candidate).to be_nil, "a tool result must not close the assistant's message"
      expect(output.halt_text).to eq("Deixa eu buscar.")
    end
  end

  describe "with the guardrail filter (RFC-0009 §3.2)" do
    let(:filter) { Insika::Safety::OutputFilter.new }

    it "publishes the redacted text, and the retained tail lands in the right message" do
      output = build(filter: filter)
      output.push("cpf 123.")
      output.push("456.789-01") # the match only completes here, and the tail is held back
      output.message_ended(message)

      expect(output.candidate).to eq("cpf [REDACTED:cpf]")
      expect(emitted.map(&:last).join).to eq("cpf [REDACTED:cpf]")
    end
  end

  describe "#publish" do
    it "emits the answer once and returns it" do
      output = build

      expect(output.publish("pronto")).to eq("pronto")
      expect(emitted).to eq([[:content, "pronto"]])
    end

    it "emits nothing for an empty answer — there is nothing to deliver" do
      output = build

      expect(output.publish("")).to eq("")
      expect(emitted).to be_empty
    end
  end
end
