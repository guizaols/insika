# frozen_string_literal: true

require "spec_helper"

# C3 — the versioned negative list (RFC §4.2): things the harvester must
# never propose. One matcher, two inputs — the committed NEGATIVE.md file
# shape and the profile's `harvest.negative_list` array — so a rule cannot
# exist in one and not the other (the E2 drift guard).
RSpec.describe Insika::Harvest::NegativeList do
  let(:file_body) do
    <<~MD
      # Negative list — what the harvest may never propose

      ## Restrictions
      - `no-competitor-prices` — "concorrente" — never mention competitors
      - `no-refund-policy` — /nao devolvemos/i — the refund policy is the human's answer
      - `no-promise` — "garantimos a troca" —
    MD
  end

  let(:array_shape) do
    [
      { "rule" => "no-competitor-prices", "pattern" => "concorrente",
        "note" => "never mention competitors" },
      { "rule" => "no-refund-policy", "pattern" => "/nao devolvemos/i",
        "note" => "the refund policy is the human's answer" },
      { "rule" => "no-promise", "pattern" => "garantimos a troca", "note" => "" }
    ]
  end

  it "parses BOTH shapes to the same rules (the drift guard's premise)" do
    from_file = described_class.parse(file_body)
    from_array = described_class.parse(array_shape)

    expect(from_file.rules.map(&:rule)).to eq(%w[no-competitor-prices no-refund-policy no-promise])
    expect(from_file.rules.map(&:pattern)).to eq(from_array.rules.map(&:pattern))
    expect(from_file.rules.map(&:regexp)).to eq(from_array.rules.map(&:regexp))
  end

  it "matches a literal phrase case+accent-folded at word boundaries" do
    list = described_class.parse(array_shape)
    expect(list.matches("a CONCORRENTE cobra mais")).to include(a_rule("no-competitor-prices"))
    # accented AND case-folded
    expect(list.matches("A NÃO DEVOLVEMOS nada")).to include(a_rule("no-refund-policy"))
  end

  it "a regex rule matches — raw and folded text (the pack may write either spelling)" do
    list = described_class.parse(array_shape)
    expect(list.matches("não devolvemos em caso de arrependimento")).to include(a_rule("no-refund-policy"))
    expect(list.matches("NAO DEVOLVEMOS em caso de arrependimento")).to include(a_rule("no-refund-policy"))
  end

it "word boundaries hold — a mid-word occurrence is NOT a phrase match" do
      list = described_class.parse(array_shape)
      expect(list.matches("proconcorrentefollowup")).to be_empty
    end

    it "matches_name is the stricter substring reading (a banned token is banned even mid-word)" do
      list = described_class.parse(array_shape)
      expect(list.matches_name("proconcorrentefollowup")).to include(a_rule("no-competitor-prices"))
      expect(list.matches("proconcorrentefollowup")).to be_empty
    end

  it "empty list (nil input) matches nothing" do
    list = described_class.parse(nil)
    expect(list.rules).to eq([])
    expect(list.matches("concorrente")).to be_empty
    expect(list.reject_counts("concorrente")).to eq({})
  end

  it "reject_counts returns { rule => count } for every matching rule" do
    list = described_class.parse(array_shape)
    counts = list.reject_counts("concorrente não devolvemos")
    expect(counts).to eq("no-competitor-prices" => 1, "no-refund-policy" => 1)
  end

  describe "parse vs parse!" do
    it "a malformed line -> parse returns nil for the WHOLE list (half a list is worse than none)" do
      bad = file_body + "- this line is not a rule\n"
      expect(described_class.parse(bad)).to be_nil
    end

    it "a malformed line -> parse! raises naming the defect" do
      bad = file_body + "- this line is not a rule\n"
      expect { described_class.parse!(bad) }
        .to raise_error(Insika::ValidationError, /line 7/)
    end

    it "an array entry without a rule id -> parse! raises naming it" do
      bad = array_shape + [ { "pattern" => "concorrente" } ]
      expect { described_class.parse!(bad) }
        .to raise_error(Insika::ValidationError, /rule/)
    end

    it "a bad regex in the file -> parse! raises; parse returns nil" do
      bad = file_body.sub("/nao devolvemos/i", "/(unclosed/i")
      expect { described_class.parse!(bad) }.to raise_error(Insika::ValidationError, /regex/)
      expect(described_class.parse(bad)).to be_nil
    end
  end

  describe "a versioned NEGATIVE.md (the drift guard)" do
    let(:list) do
      described_class.parse(<<~MD)
        ## Restrictions

        - `no-competitor-prices` — "concorrente" — never mention competitors or their prices
        - `no-competitor-store` — "outra loja" — never steer the customer to another store
        - `no-refund-promise` — /nao devolvemos/i — the refund policy is the human's answer, never a skill's
        - `no-delivery-promise` — "garantimos a entrega" — delivery promises are the human's call
      MD
    end

    it "parses and matches its own rules — a broken file or a drifted matcher FAILS the suite" do
      expect(list).to_not be_nil
      list.rules.each { |r| expect(list.matches(r.pattern)).to include(r) }
    end

    it "rejects a representative candidate naming a banned phrase" do
      expect(list.matches("não devolvemos em caso de arrependimento")).to_not be_empty
      expect(list.matches("compare com a concorrente")).to_not be_empty
    end
  end

  def a_rule(id)
    satisfy("rule #{id.inspect}") { |rule| rule.rule == id }
  end
end