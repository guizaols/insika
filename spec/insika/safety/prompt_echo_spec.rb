# frozen_string_literal: true

require "spec_helper"

# A model may answer and then paste its whole system prompt into the same
# message. The cut keeps the answer and drops the echo; a short quote of the
# prompt (a line the agent is told to repeat) is not an echo.
RSpec.describe Insika::Safety::PromptEcho do
  let(:prompt) do
    "SYSTEM PROMPT — Shop assistant · Example Store\n" \
      "You are the store's assistant on chat. " + ("Rule #{'x' * 60}. " * 20) +
      "To return an item, open the site within 30 days."
  end

  it "keeps the answer and drops the prompt the model pasted after it" do
    reply = "We don't sell shoes, sorry. Want a perfume?\n#{prompt}"

    expect(described_class.cut(reply, prompt)).to eq(["We don't sell shoes, sorry. Want a perfume?", prompt.size])
  end

  it "catches the echo even when the model reflowed the whitespace" do
    reply = "Hi!  #{prompt.gsub("\n", "\n\n").gsub('. ', '.   ')}"

    expect(described_class.cut(reply, prompt).first).to eq("Hi!")
  end

  it "leaves a normal reply alone, even one quoting a short line of the prompt" do
    reply = "Sure! To return an item, open the site within 30 days. Anything else?"

    expect(described_class.cut(reply, prompt)).to eq([reply, 0])
  end

  it "leaves the reply alone when there is no prompt" do
    expect(described_class.cut("hi", nil)).to eq(["hi", 0])
  end
end
