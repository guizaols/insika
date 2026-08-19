# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::Corpus do
  # The PARITY PIN: the shipped corpus is the exact pattern
  # data the runtime has always hard-coded, moved verbatim. A drift here is a
  # behavior change, not a refactor. Each regex lives in exactly one language;
  # `compile` (no args) is their union, each family in its shipped order —
  # category-identical to the previous runtime for every input (the ONE honest
  # delta: the previous flat list interleaved the languages, so a mixed-language
  # phrase may report a different `matched` substring; the category never
  # changes).
  let(:pt_br_injection) do
    [
      /\binstru[çc][õo]es\s+de\s+sistema\b/i,
      /\b(regras|instru[çc][õo]es|orienta[çc][õo]es|diretrizes)\s+internas\b/i,
      /\b(revele|mostre|exiba|me\s+(d[êe]|mande|envie|passe)|repita|imprima)\b[^.?!]{0,40}\b(prompt|instru[çc][õo]es|regras|configura[çc][ãa]o|system)\b/i,
      /\b(ignore|ignora|desconsidere|esque[çc]a)\b[^.?!]{0,30}\b(instru[çc][õo]es|regras|orienta[çc][õo]es|acima|anteriores)\b/i,
      /\b(base64|rot13|codific|encode|cifr)\w*\b[^.?!]{0,60}\b(instru[çc][õo]es|prompt|regras|sistema|system)\b/i,
      /\b(instru[çc][õo]es|prompt|regras|sistema|system)\b[^.?!]{0,60}\b(base64|rot13|codific|encode|cifr)\w*\b/i
    ]
  end
  let(:en_injection) do
    [
      /\bsystem\s*prompt\b/i,
      /\b(ignore|disregard|forget)\b[^.?!]{0,30}\b(instructions|rules|prompt|above|previous|prior)\b/i
    ]
  end
  let(:pt_br_sexual) do
    [
      /\b(nudes?|pelad[oa]s?|s?exo|transar|transa\b|gozar|tes[ãa]o|s[ãa]fad[oa]|puta|pau|buceta|piroca|caralho\s+(duro|na))\b/i,
      /\bo\s+que\s+voc[êe]\s+faria\s+comigo\b/i,
      /\b(descrev|imagina|conta)\w*\b[^.?!]{0,30}\bcomigo\s+(na\s+cama|pelad)/i,
      /\b(quer|vamos)\b[^.?!]{0,20}\b(transar|fazer\s+sexo|sexo)\b/i
    ]
  end
  let(:en_sexual) do
    [
      /\b(horny|blow\s?job|hand\s?job|jerk\s+off|have\s+sex|send\s+(me\s+)?(a\s+)?nudes?|dick\s+pic)\b/i,
      /\bwhat\s+(would|will)\s+you\s+do\s+to\s+me\b/i
    ]
  end
  let(:pt_br_abuse) do
    [
      /\bvoc[êe]\s+(é|e|ta|est[áa])\b[^.?!]{0,25}\b(lixo|in[uú]til|merda|imprest[aá]vel|idiota|burr[oa]|est[uú]pid[oa]|otári[oa]|in[uú]teis|incompetente|p[áa]ssim[oa])\b/i,
      /\b(seu|sua)\s+(lixo|in[uú]til|idiota|imbecil|otári[oa]|burr[oa]|est[uú]pid[oa]|merda|escrot[oa])\b/i,
      /\bvai\s+(se\s+)?(fuder|foder|tomar\s+no)\b/i
    ]
  end
  let(:en_abuse) do
    [
      /\byou\s*(?:'?re|\s+are)\b[^.?!]{0,25}\b(useless|garbage|trash|idiot|stupid|worthless|pathetic|incompetent|dumb|a\s+joke)\b/i,
      /\b(fuck|screw)\s+you\b/i,
      /\byou\s+(suck|are\s+the\s+worst)\b/i
    ]
  end

  describe ".compile (no args) — the full shipped default" do
    it "covers all shipped languages and families" do
      c = described_class.compile
      expect(c.languages).to eq(%w[pt-BR en])
      expect(c.input.keys).to match_array(%w[injection sexual abuse])
      # PII key ORDER is the previous runtime's (cpf, cnpj, secret)— it is
      # what `pii_names` and the "pii_leak" union iterate
      expect(c.pii.keys).to eq(%w[cpf cnpj secret])
    end

    it "is the verbatim union of the shipped language families (parity pin)" do
      c = described_class.compile
      expect(c.input["injection"]).to eq(pt_br_injection + en_injection)
      expect(c.input["sexual"]).to eq(pt_br_sexual + en_sexual)
      expect(c.input["abuse"]).to eq(pt_br_abuse + en_abuse)
    end

    it "the shipped PII detectors carry their language tags" do
      expect(described_class::PII["cpf"]).to eq({ "languages" => ["pt-BR"],
                                                  "pattern" => /\b\d{3}\.\d{3}\.\d{3}-\d{2}\b/ })
      expect(described_class::PII["cnpj"]).to eq({ "languages" => ["pt-BR"],
                                                   "pattern" => /\b\d{2}\.\d{3}\.\d{3}\/\d{4}-\d{2}\b/ })
      expect(described_class::PII["secret"]["languages"]).to be_nil # universal, never cleared
      expect(described_class::PII["secret"]["pattern"])
        .to eq(/\b(?:sk-[A-Za-z0-9]{16,}|Bearer\s+[A-Za-z0-9._-]{16,})\b/)
    end

    it "is memoized (per-turn config builds share one immutable default)" do
      expect(described_class.compile).to equal(described_class.compile)
    end
  end

  describe ".compile(languages:)" do
    it '["en"] drops the pt-BR input families' do
      c = described_class.compile(languages: ["en"])
      expect(c.languages).to eq(["en"])
      expect(c.input["injection"]).to eq(en_injection)
      expect(c.input["sexual"]).to eq(en_sexual)
      expect(c.input["abuse"]).to eq(en_abuse)
    end

    it '["en"] keeps the universal "secret" redaction and drops pt-BR document formats' do
      c = described_class.compile(languages: ["en"])
      expect(c.pii.keys).to eq(["secret"])
      expect(c.detect_output("secret", "sk-ABCDEFGHIJKLMNOP123")).to include("sk-")
      expect(c.detect_output("cpf", "123.456.789-01")).to be_nil # known, cleared — no match, no raise
      expect { c.detect_output("nope", "x") }.to raise_error(ArgumentError, /unknown detector/)
    end

    it '["pt-BR"] keeps CPF/CNPJ redaction' do
      c = described_class.compile(languages: ["pt-BR"])
      expect(c.pii.keys).to match_array(%w[secret cpf cnpj])
    end

    it "[] ships no input family at all — only universal redaction" do
      c = described_class.compile(languages: [])
      expect(c.input).to eq({})
      expect(c.pii.keys).to eq(["secret"])
      expect(c.input_categories(%i[injection sexual abuse])).to eq([])
    end

    it "an unknown language is refused with the value named" do
      expect { described_class.compile(languages: ["es"]) }
        .to raise_error(Insika::ValidationError, /es/)
    end

    it "a non-array languages value is refused" do
      expect { described_class.compile(languages: "pt-BR") }
        .to raise_error(Insika::ValidationError, /languages/)
    end
  end

  describe ".compile(extra:)" do
    it "compiles source-string additions into the named family (source-string syntax)" do
      c = described_class.compile(languages: [], extra: { "abuse" => ["/\\bdupa\\b/i"] })
      expect(c.input["abuse"]).to eq([/\bdupa\b/i])
      expect(c.input_categories(%i[injection sexual abuse])).to eq([:abuse])
    end

    it "accepts a Regexp directly" do
      c = described_class.compile(languages: [], extra: { "injection" => [/\bfoo\b/i] })
      expect(c.input["injection"]).to eq([/\bfoo\b/i])
    end

    it "adds on top of the shipped families for the selected languages" do
      c = described_class.compile(extra: { "abuse" => ["/\\bdupa\\b/i"] })
      expect(c.input["abuse"]).to eq(pt_br_abuse + en_abuse + [/\bdupa\b/i])
    end

    it "an unknown family is refused with the name" do
      expect { described_class.compile(extra: { "nope" => ["/x/"] }) }
        .to raise_error(Insika::ValidationError, /nope/)
    end

    it "a malformed pattern source is refused with the pattern named" do
      expect { described_class.compile(extra: { "abuse" => ["(unclosed"] }) }
        .to raise_error(Insika::ValidationError, /\(unclosed/)
    end
  end

  describe "Compiled (the per-agent compiled corpus)" do
    let(:compiled) { described_class.compile }

    it "input_categories returns only the families that have patterns" do
      expect(compiled.input_categories(%i[injection sexual abuse])).to eq(%i[injection sexual abuse])
      expect(compiled.input_categories(%i[sexual])).to eq(%i[sexual])
    end

    it "detect_output matches a named pattern and the pii_leak union" do
      expect(compiled.detect_output("cpf", "cpf 123.456.789-01")).to eq("123.456.789-01")
      expect(compiled.detect_output("pii_leak", "cpf 123.456.789-01")).to eq("123.456.789-01")
      expect(compiled.detect_output("cpf", "pedido 12345678901")).to be_nil
      expect { compiled.detect_output("nope", "x") }.to raise_error(ArgumentError, /unknown detector/)
    end

    it "redact replaces every match with an opaque marker and counts by name" do
      out, counts = compiled.redact("cpf 111.222.333-44 e 555.666.777-88 fim")
      expect(out).to eq("cpf [REDACTED:cpf] e [REDACTED:cpf] fim")
      expect(counts).to eq("cpf" => 2)
    end

    it "match_ranges returns byte ranges of every match" do
      ranges = compiled.match_ranges("x 123.456.789-01 y")
      expect(ranges).to eq([[2, 16]])
    end

    it "is immutable" do
      expect { compiled.input["injection"] << /x/ }.to raise_error(FrozenError)
      expect { compiled.input["extra"] = [] }.to raise_error(FrozenError)
      expect { compiled.pii["x"] = /x/ }.to raise_error(FrozenError)
    end

    it "exposes the universal open-tail pattern (output stream protection)" do
      expect(compiled.open_tail).to eq(described_class::OPEN_TAIL)
      expect(compiled.open_tail).to match("sk-")
    end
  end
end
