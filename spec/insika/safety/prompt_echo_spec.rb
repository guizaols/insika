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

  # The prompt is the same on every turn of an agent; squeezing its whitespace
  # again for every reply was a regex pass over the whole prompt per turn.
  it "squeezes a given prompt once, not on every reply" do
    allow(described_class).to receive(:squeeze).and_call_original
    long = "#{'An ordinary reply without any echo. ' * 20}"

    2.times { described_class.cut(long, "#{prompt} (variant squeezed once)") }
    expect(described_class).to have_received(:squeeze).once
  end

  it "leaves a reply shorter than an echo alone without reading the prompt" do
    allow(described_class).to receive(:squeeze).and_call_original

    expect(described_class.cut("Short answer.", prompt)).to eq(["Short answer.", 0])
    expect(described_class).not_to have_received(:squeeze)
  end
end
