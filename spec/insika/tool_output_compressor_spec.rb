# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::ToolOutputCompressor do
  def tool_msg(content, id: "call-1", keys: :symbol)
    m = { role: :tool, content: content, tool_call_id: id }
    keys == :string ? m.transform_keys(&:to_s) : m
  end

  let(:big_output) { ("catalog page with many product rows and long descriptions " * 20).strip }
  let(:other_output) { ("totally different payload " * 20).strip }

  describe ".compress_transcript" do
    it "the 2nd byte-identical tool result becomes a back-reference; the 1st stays full" do
      out = described_class.compress_transcript([tool_msg(big_output, id: "a"),
                                                 tool_msg(big_output, id: "b")])

      expect(out[0][:content]).to eq(big_output) # full
      expect(out[1][:content]).to match(/\A\[repeated tool output — byte-identical/)
      expect(out[1][:content]).to include("One-line summary")
      expect(out[1][:content].length).to be < 300 # tokens drop vs the ~800-char body
      expect(out[1][:tool_call_id]).to eq("b") # identity preserved
    end

    it "three identical results: only the first is full" do
      out = described_class.compress_transcript(3.times.map { |i| tool_msg(big_output, id: "c#{i}") })

      expect(out.map { |m| m[:content] }).to eq(
        [big_output, out[1][:content], out[2][:content]]
      )
      expect(out[1][:content]).to eq(out[2][:content])
    end

    it "different content never dedupes (digest is exact-match only)" do
      out = described_class.compress_transcript([tool_msg(big_output),
                                                 tool_msg(other_output)])

      expect(out[0][:content]).to eq(big_output)
      expect(out[1][:content]).to eq(other_output)
    end

    it "a later identical result after different ones still dedupes against the first" do
      out = described_class.compress_transcript([tool_msg(big_output),
                                                 tool_msg(other_output),
                                                 tool_msg(big_output)])

      expect(out[0][:content]).to eq(big_output)
      expect(out[1][:content]).to eq(other_output)
      expect(out[2][:content]).to match(/\A\[repeated tool output/)
    end

    it "short outputs stay untouched (the back-reference would cost more)" do
      short = "small"
      out = described_class.compress_transcript([tool_msg(short), tool_msg(short)])

      expect(out.map { |m| m[:content] }).to eq([short, short])
    end

    # In the 200–~260-char band the old code replaced a repeat with a LONGER
    # back-reference (boilerplate + up to 161-char summary) — the transcript
    # grew. The repeat must only be replaced when the ref is actually shorter.
    it "a repeat is replaced only when the back-reference is strictly SHORTER than the content (C3)" do
      mid = "x" * 240 # >= MIN_LENGTH, but shorter than any full back-reference
      out = described_class.compress_transcript([tool_msg(mid), tool_msg(mid)])
      expect(out[1][:content]).to eq(mid) # kept full: replacing would grow the transcript

      long = "y" * 600
      out2 = described_class.compress_transcript([tool_msg(long), tool_msg(long)])
      expect(out2[1][:content]).to match(/\A\[repeated tool output/)
    end

    # The eviction unit cut drops the OLDEST unit first — the original this
    # back-reference points at. A positional pointer ("see above") that
    # survives its target is a dangle in the model's context (C3): the
    # summary is the content and stands alone.
    it "a back-reference carries NO positional pointer — eviction cannot orphan it (C3)" do
      out = described_class.compress_transcript([tool_msg(big_output), tool_msg(big_output)])

      expect(out[1][:content]).not_to include("see above")
      expect(out[1][:content]).to include("One-line summary") # self-sufficient
    end

    it "user/assistant messages are never touched, even with identical content" do
      msgs = [{ role: :user, content: big_output }, { role: :assistant, content: big_output }]
      out = described_class.compress_transcript(msgs + msgs)

      expect(out.map { |m| m[:content] }).to eq([big_output, big_output, big_output, big_output])
    end

    it "string-keyed messages are preserved with string keys" do
      out = described_class.compress_transcript([tool_msg(big_output, keys: :string),
                                                 tool_msg(big_output, keys: :string)])

      expect(out[0]).to have_key("content")
      expect(out[1]["content"]).to match(/\A\[repeated tool output/)
      expect(out[1]).not_to have_key(:content)
    end

    it "a non-Hash entry passes through untouched" do
      raw = "not a message"
      out = described_class.compress_transcript([raw])

      expect(out).to eq([raw])
    end

    it "the one-line summary is the first line, capped at SUMMARY_LIMIT" do
      multi = "SUMMARY LINE ONE " + ("filler " * 60) + "\nsecond line\nthird"
      out = described_class.compress_transcript([tool_msg(multi), tool_msg(multi)])

      expect(out[1][:content]).to include("SUMMARY LINE ONE")
      expect(out[1][:content]).not_to include("second line")

      long_first_line = "x" * (described_class::SUMMARY_LIMIT * 3 + 50)
      out2 = described_class.compress_transcript([tool_msg(long_first_line), tool_msg(long_first_line)])
      summary = out2[1][:content].match(/One-line summary: (.+)\]/)[1]
      expect(summary.length).to be <= described_class::SUMMARY_LIMIT + 1 # + ellipsis
      expect(summary).to end_with("…")
    end

    it "repeated tool results drop the transcript's token estimate (the real replay win)" do
      transcript = 6.times.flat_map do |i|
        [tool_msg("user turn #{i}", id: "u#{i}"), tool_msg(big_output, id: "t#{i}")]
      end
      plain = transcript.map { |m| m[:content] }.join(" ")
      compressed = described_class.compress_transcript(transcript).map { |m| m[:content] }.join(" ")

      expect(Insika::TokenEstimator.estimate(compressed))
        .to be < Insika::TokenEstimator.estimate(plain)
    end
  end
end