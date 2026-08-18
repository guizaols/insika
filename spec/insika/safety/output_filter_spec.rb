# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::OutputFilter do
  # Feeds `text` split into two chunks at `offset`, returns the full emitted output
  # (deltas + flush).
  def emit_split(text, offset)
    f = described_class.new
    out = +""
    out << f.push(text[0...offset])
    out << f.push(text[offset..])
    out << f.flush
    out
  end

  describe "single-chunk redaction" do
    it "redacts a whole PII value and preserves the surrounding text" do
      f = described_class.new
      emitted = f.push("olá, seu cpf 123.456.789-01 está ok") + f.flush
      expect(emitted).to eq("olá, seu cpf [REDACTED:cpf] está ok")
      expect(f.output).to eq(emitted)
      expect(f.redaction_counts).to eq("cpf" => 1)
    end

    it "passes clean text straight through" do
      f = described_class.new
      out = f.push("seu pedido chega amanhã") + f.flush
      expect(out).to eq("seu pedido chega amanhã")
    end
  end

  # THE critical guarantee (RFC): a value split across a chunk boundary at ANY
  # offset must NEVER be emitted in the clear.
  describe "split across a chunk boundary at every offset" do
    samples = {
      "cpf" => "seu cpf é 123.456.789-01 obrigado",
      "cnpj" => "cnpj da loja 12.345.678/0001-99 confere",
      "secret" => "o token sk-ABCDEFGHIJKLMNOP0123 nao pode vazar"
    }

    samples.each do |name, text|
      it "never leaks a #{name} regardless of split point" do
        raw = Insika::Safety::Detectors.detect(name, text)
        (0..text.length).each do |offset|
          out = emit_split(text, offset)
          expect(out).not_to include(raw), "leaked #{name} at split offset #{offset}: #{out.inspect}"
          expect(out).to include("[REDACTED:#{name}]"), "did not redact at offset #{offset}: #{out.inspect}"
        end
      end
    end

    it "delta-by-delta (one char per chunk) still redacts" do
      text = "cpf 123.456.789-01 fim"
      f = described_class.new
      out = +""
      text.each_char { |c| out << f.push(c) }
      out << f.flush
      expect(out).not_to include("123.456.789-01")
      expect(out).to include("[REDACTED:cpf]")
      expect(f.output).to eq(out)
    end
  end

  describe "unbounded secret beyond a fixed window" do
    it "holds an in-progress sk- token until it terminates, never emitting it raw" do
      f = described_class.new
      long = "sk-" + ("A".."Z").to_a.join * 4 # > 100 chars of valid key body
      out = +""
      # stream it in small pieces
      ("prefixo " + long + " sufixo").chars.each_slice(3) { |s| out << f.push(s.join) }
      out << f.flush
      expect(out).to include("[REDACTED:secret]")
      expect(out).not_to include(long)
      expect(out).to include("prefixo").and include("sufixo")
    end
  end

  describe "#output is the concatenation of everything emitted" do
    it "matches the streamed deltas exactly" do
      f = described_class.new
      streamed = +""
      ["parte um 123.", "456.789-01 par", "te dois"].each { |d| streamed << f.push(d) }
      streamed << f.flush
      expect(f.output).to eq(streamed)
      expect(streamed).to include("[REDACTED:cpf]")
    end
  end

  describe "with a compiled corpus (RFC-0036 C2)" do
    it "an EN-only corpus does not redact pt-BR document formats, still redacts secrets" do
      f = described_class.new(corpus: Insika::Safety::Corpus.compile(languages: ["en"]))
      out = f.push("cpf 123.456.789-01 e token sk-ABCDEFGHIJKLMNOP123") + f.flush
      expect(out).to include("123.456.789-01")
      expect(out).to include("[REDACTED:secret]")
      expect(f.redaction_counts).to eq("secret" => 1)
    end
  end
end
