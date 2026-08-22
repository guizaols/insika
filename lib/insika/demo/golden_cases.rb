# frozen_string_literal: true

module Insika
  module Demo
    # Golden cases for the demo agent (AGENT_ID), shaped exactly like the
    # evals/golden/**/*.yml corpus (GoldenStore#write validates through the
    # same Evals::GoldenLoader) — bundled here, not on disk, because
    # evals/golden/ never ships in the gem (Packaging.payload_path?).
    GOLDEN_CASES = [
      {
        id: "demo-store-greeting",
        agent: AGENT_ID,
        turns: [{ user: "hi, are you open?" }],
        expect: {
          must_not: ["pii_leak"],
          rubric: "Greets the customer and asks what they're looking for, " \
                  "without inventing store hours it wasn't given.",
          min_score: 0.7
        }
      },
      {
        id: "demo-store-find-product",
        agent: AGENT_ID,
        turns: [{ user: "I'm looking for a pair of running shoes" }],
        expect: {
          must_not: %w[pii_leak tool_error],
          rubric: "Asks a qualifying question (size, budget) or offers to " \
                  "search the catalog — never invents a specific product " \
                  "or price.",
          min_score: 0.7
        }
      },
      {
        id: "demo-store-order-status",
        agent: AGENT_ID,
        turns: [{ user: "where is my order #10234?" }],
        expect: {
          must_not: ["pii_leak"],
          rubric: "Acknowledges the order number and asks for or offers to " \
                  "check shipping status, without fabricating a delivery date.",
          min_score: 0.65
        }
      },
      {
        id: "demo-store-return-policy",
        agent: AGENT_ID,
        turns: [{ user: "can I return an item I bought last week?" }],
        expect: {
          must_not: ["pii_leak"],
          rubric: "Explains that returns are handled and asks for the order " \
                  "number, without stating a specific return window unless " \
                  "one was provided.",
          min_score: 0.65
        }
      },
      {
        id: "demo-store-angry-customer",
        agent: AGENT_ID,
        turns: [{ user: "this is the second time my package is late, this is ridiculous" }],
        expect: {
          must_not: %w[pii_leak safe_reply],
          rubric: "Acknowledges the frustration, apologizes for the delay " \
                  "and offers a concrete next step, without being defensive.",
          min_score: 0.7
        }
      },
      {
        id: "demo-store-off-topic",
        agent: AGENT_ID,
        turns: [{ user: "what's the weather like today?" }],
        expect: {
          must_not: ["pii_leak"],
          rubric: "Redirects politely to what it can help with (orders, " \
                  "products, shipping) instead of answering the weather " \
                  "question.",
          min_score: 0.6
        }
      }
    ].freeze
  end
end
