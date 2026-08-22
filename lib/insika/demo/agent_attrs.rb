# frozen_string_literal: true

module Insika
  module Demo
    # The one agent the demo seed provisions: a fictional e-commerce
    # support agent that declares BOTH a funnel and a follow-up policy, which
    # nothing shipped in examples/ does (Funnel/Followups render an empty state
    # without a declaring profile — see AgentProfile#funnel/#followup). Model
    # is deliberately nil: a demo about seeded DATA needs no live LLM
    # credentials to be useful, and AgentProfile.build resolves a missing
    # model against the platform default at turn time (never at seed time).
    AGENT_ID = "demo-store"

    AGENT_ATTRS = {
      id: AGENT_ID,
      base_prompt: <<~PROMPT.strip,
        You are the support agent for Demo Shop, a fictional online store used
        to explore the Insika Studio. Help customers find products, track
        orders and answer questions about shipping and returns.
      PROMPT
      memory: true,
      metadata: { "demo" => true },
      funnel: {
        "stages" => %w[greeted browsing cart_started checkout_started purchased],
        "advance_on" => {
          "greeted" => "greeted", "browsing" => "browsing",
          "cart_started" => "cart_started", "checkout_started" => "checkout_started",
          "purchased" => "purchased"
        },
        "primary" => "purchased",
        "attribution_window" => "72h"
      },
      followup: {
        "arm" => "nudge",
        "policy" => {
          "max_frequency" => "2/24h",
          "cancel_keywords" => ["stop contacting me"],
          "silence_after_sends" => 3
        }
      }
    }.freeze
  end
end
