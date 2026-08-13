# frozen_string_literal: true

require "spec_helper"

# WS4: the pure half of intent routing — config normalization, prompt
# generation and answer parsing. The ask/usage side is the Executor's
# (executor_routing_spec).
RSpec.describe Insika::Routing do
  let(:routes) do
    { "shopping" => "the customer wants to browse products",
      "order"    => { "description" => "asks about an existing order",
                      "delegate" => "order-agent" },
      "human"    => { "description" => "the customer is frustrated or asks for a person",
                      "stuck" => true, "message" => "A person will help you." },
      "default"  => "shopping",
      "model"    => "deepseek-v4-flash" }
  end

  describe ".normalize" do
    it "extracts the entries (description / delegate / stuck / message) and the reserved keys" do
      meta = described_class.normalize(routes)

      expect(meta[:default]).to eq("shopping")
      expect(meta[:model]).to eq("deepseek-v4-flash")
      expect(meta[:entries].map(&:name)).to eq(%w[shopping order human])
      shopping = meta[:entries].find { |e| e.name == "shopping" }
      expect(shopping.description).to eq("the customer wants to browse products")
      expect(shopping.delegate).to eq("")
      expect(shopping.stuck).to be(false)

      order = meta[:entries].find { |e| e.name == "order" }
      expect(order.delegate).to eq("order-agent")

      human = meta[:entries].find { |e| e.name == "human" }
      expect(human.stuck).to be(true)
      expect(human.message).to eq("A person will help you.")
    end

    it "is nil when routes are absent or empty (routing off — parity)" do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize({})).to be_nil
    end

    it "falls back to the FIRST route as the default when none was declared" do
      meta = described_class.normalize({ "shopping" => "desc" })
      expect(meta[:default]).to eq("shopping")
    end

    it "tolerates symbol keys (an internal build) — names are stringified" do
      meta = described_class.normalize({ shopping: "desc", default: :shopping })
      expect(meta[:entries].first.name).to eq("shopping")
      expect(meta[:default]).to eq("shopping")
    end

    it "refuses a route name the classifier could never answer with" do
      expect { described_class.normalize({ "shopping for kids" => "desc" }) }
        .to raise_error(Insika::ValidationError, /may not contain spaces/)
      expect { described_class.normalize({ "order!" => "desc" }) }
        .to raise_error(Insika::ValidationError)
    end

    it "refuses a routing config with zero routes (a silent off is a config error)" do
      expect { described_class.normalize({ "default" => "x" }) }
        .to raise_error(Insika::ValidationError, /at least one route/)
    end
  end

  describe ".classifier_prompt" do
    it "is auto-generated from the descriptions — one line per route, no prompt file" do
      prompt = described_class.classifier_prompt(described_class.normalize(routes))

      expect(prompt).to include("-shopping: the customer wants to browse products")
      expect(prompt).to include("-order: asks about an existing order")
      expect(prompt).to include("-human: the customer is frustrated or asks for a person")
      expect(prompt).to include("Reply with ONLY the intent name")
      expect(prompt).not_to include("order-agent") # actions never leak into the prompt
    end
  end

  describe ".parse" do
    let(:meta) { described_class.normalize(routes) }

    it "an exact name answers that route" do
      expect(described_class.parse("order", meta)).to eq(:order)
    end

    it "tolerates case, punctuation and a trailing period" do
      expect(described_class.parse("Order.", meta)).to eq(:order)
      expect(described_class.parse("  human  ", meta)).to eq(:human)
    end

    it "an unknown token, prose or empty answer falls back to the DEFAULT (deterministic)" do
      expect(described_class.parse("refund", meta)).to eq(:shopping)
      expect(described_class.parse("I am not sure what this is about", meta)).to eq(:shopping)
      expect(described_class.parse("", meta)).to eq(:shopping)
      expect(described_class.parse(nil, meta)).to eq(:shopping)
    end

    it "the default is a real route, never invented" do
      meta2 = described_class.normalize({ "shopping" => "desc" })
      expect(described_class.parse("anything at all", meta2)).to eq(:shopping)
    end
  end
end
