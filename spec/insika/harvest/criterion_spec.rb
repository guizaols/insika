# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# C4 — the frozen conversion criterion, parsed from harvest/CRITERION.md's
# fenced yaml block (D5 — the parity shape: strict keys, no defaults, whole
# bytes sha). A skill may land only when the store's ruler is not measurably
# worse than the accepted state; the file IS the criterion — the profile
# carries no thresholds.
RSpec.describe Insika::Harvest::Criterion do
  let(:tmp) { Dir.mktmpdir("harvest-criterion") }
  after { FileUtils.remove_entry(tmp) }

  def write_criterion(body, name: "CRITERION.md")
    path = File.join(tmp, name)
    File.write(path, body)
    path
  end

  let(:valid_yaml) do
    <<~YAML
      version: 1
      metric: primary
      window: 72h
      threshold: 0.05
      min_span: 28d
    YAML
  end

  def fenced(body)
    <<~MD
      # harvest/CRITERION.md — frozen BEFORE the first promotion.

      > A skill may land only when the store's ruler is not measurably worse
      > than the accepted state.

      ```yaml
      #{body}
      ```
    MD
  end

  it "loads the committed harvest/CRITERION.md — a doc edit that breaks the block fails the suite" do
    path = File.expand_path("../../../harvest/CRITERION.md", __dir__)
    criterion = described_class.load(path)
    expect(criterion.rule.version).to eq(1)
    expect(criterion.rule.metric).to eq("primary")
    expect(criterion.rule.window).to eq("72h")
    expect(criterion.rule.threshold).to eq(0.05)
    expect(criterion.rule.min_span).to eq("28d")
    expect(criterion.sha).to match(/\Asha256:[0-9a-f]{64}\z/)
  end

  it "parses every field of the rule from the FIRST yaml fence" do
    criterion = described_class.load(write_criterion(fenced(valid_yaml)))
    rule = criterion.rule
    expect(rule.version).to eq(1)
    expect(rule.metric).to eq("primary")
    expect(rule.window).to eq("72h")
    expect(rule.threshold).to eq(0.05)
    expect(rule.min_span).to eq("28d")
    expect(criterion.to_h).to include(metric: "primary")
    expect(criterion.path).to eq(File.join(tmp, "CRITERION.md"))
  end

  it "refuses a missing key — no defaults, ever (a number the machine filled in is not pre-registered)" do
    yaml = valid_yaml.sub(/window: 72h\n/, "")
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /missing.*window/)
  end

  it "refuses an unknown key — a number nobody pre-registered must not load" do
    yaml = valid_yaml + "magic_multiplier: 0.99\n"
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /unknown.*magic_multiplier/)
  end

  it "refuses a malformed window (not /\\A\\d+h\\z/)" do
    yaml = valid_yaml.sub("72h", "72hours")
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /window.*72hours/)
  end

  it "refuses a malformed min_span (not /\\A\\d+d\\z/)" do
    yaml = valid_yaml.sub("28d", "28")
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /min_span.*28/)
  end

  it "refuses a threshold outside 0..1" do
    yaml = valid_yaml.sub("0.05", "1.5")
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /threshold/)
  end

  it "refuses a non-Float threshold (a number the yaml filled in differently is still a drift)" do
    yaml = valid_yaml.sub("0.05", "5")
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /threshold/)
  end

  it "refuses a non-Integer version" do
    yaml = valid_yaml.sub("version: 1", "version: one")
    path = write_criterion(fenced(yaml))
    expect { described_class.load(path) }
      .to raise_error(Insika::ValidationError, /version/)
  end

  it "raises ConfigError when the file is absent" do
    expect { described_class.load(File.join(tmp, "nope.md")) }
      .to raise_error(Insika::ConfigError, /criterion/)
  end

  it "raises ConfigError when the file has no yaml block" do
    path = write_criterion("# CRITERION\nprose, no block\n")
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