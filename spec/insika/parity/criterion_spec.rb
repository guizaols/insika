# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# C5 — the frozen criterion, parsed from evals/PARITY.md's fenced yaml block.
# The whole file's bytes are hashed, prose included: an edit to the rationale
# invalidates the frozen rule, which is correct — the rationale is what makes
# the numbers reviewable.
RSpec.describe Insika::Parity::Criterion do
  let(:tmp) { Dir.mktmpdir("parity-criterion") }
  after { FileUtils.remove_entry(tmp) }

  def write_criterion(body, name: "PARITY.md")
    path = File.join(tmp, name)
    File.write(path, body)
    path
  end

  let(:valid_yaml) do
    <<~YAML
      version: 1
      unit: exchange
      window_days: 7
      pairs_per_day: 30
      min_decided: 200
      min_judge_models: 3
      both_orders: true
      estimator: wilson_lower_95
      win_or_tie_floor: 0.80
      worse_rate_ceiling: 0.10
      undecided_rate_ceiling: 0.20
      incomplete_rate_ceiling: 0.20
      per_agent_min_decided: 50
      per_agent_win_or_tie_floor: 0.70
      human_assisted: report_only
      silent: report_only
    YAML
  end

  def fenced(body)
    <<~MD
      # PARITY
      prose that humans read
      ```yaml
      #{body}
      ```
      more prose
    MD
  end

  it "loads the committed evals/PARITY.md — a doc edit that breaks the block fails the suite" do
    path = File.expand_path("../../../evals/PARITY.md", __dir__)
    criterion = described_class.load(path)
    expect(criterion.rule.version).to eq(1)
    expect(criterion.rule.window_days).to eq(7)
    expect(criterion.rule.win_or_tie_floor).to eq(0.80)
    expect(criterion.sha).to match(/\Asha256:[0-9a-f]{64}\z/)
  end

  it "parses every field of the rule from the FIRST yaml fence" do
    criterion = described_class.load(write_criterion(fenced(valid_yaml)))
    rule = criterion.rule
    expect(rule.unit).to eq("exchange")
    expect(rule.window_days).to eq(7)
    expect(rule.pairs_per_day).to eq(30)
    expect(rule.min_decided).to eq(200)
    expect(rule.min_judge_models).to eq(3)
    expect(rule.both_orders).to be(true)
    expect(rule.estimator).to eq("wilson_lower_95")
    expect(rule.win_or_tie_floor).to eq(0.80)
    expect(rule.worse_rate_ceiling).to eq(0.10)
    expect(rule.undecided_rate_ceiling).to eq(0.20)
    expect(rule.incomplete_rate_ceiling).to eq(0.20)
    expect(rule.per_agent_min_decided).to eq(50)
    expect(rule.per_agent_win_or_tie_floor).to eq(0.70)
    expect(rule.human_assisted).to eq("report_only")
    expect(rule.silent).to eq("report_only")
    expect(criterion.to_h).to include(window_days: 7)
  end

  it "refuses a missing key — no defaults, ever" do
    yaml = valid_yaml.sub(/min_decided: 200\n/, "")
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /missing.*min_decided/)
  end

  it "refuses an unknown key — a number nobody pre-registered must not load" do
    yaml = valid_yaml + "new_fancy_number: 0.99\n"
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /unknown.*new_fancy_number/)
  end

  it "raises ConfigError when the file is absent" do
    expect { described_class.load(File.join(tmp, "nope.md")) }
      .to raise_error(Insika::ConfigError, /criterion/)
  end

  it "raises ConfigError when the file has no yaml block" do
    path = write_criterion("# PARITY\nprose, no block\n")
    expect { described_class.load(path) }
      .to raise_error(Insika::ConfigError, /yaml/)
  end

  it "hashes the WHOLE file — changing the prose invalidates the frozen rule" do
    path = write_criterion(fenced(valid_yaml))
    before = described_class.load(path).sha

    File.write(path, "# edited rationale\n" + fenced(valid_yaml))
    after = described_class.load(path).sha

    expect(after).not_to eq(before)
    expect(after).to match(/\Asha256:[0-9a-f]{64}\z/)
  end

  it "uses only the first fence when several blocks exist" do
    body = fenced(valid_yaml) + "\n```yaml\ncompletely: different\n```\n"
    criterion = described_class.load(write_criterion(body))
    expect(criterion.rule.version).to eq(1)
  end
end
