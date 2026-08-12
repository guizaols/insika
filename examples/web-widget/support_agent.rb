# frozen_string_literal: true

# The ENGINE side of the widget example. Deliberately an ordinary agent — nothing
# here knows a channel exists. That is the point: a channel is an edge, not a
# property of the agent, so the same agent serves /v1/responses, the Studio and a
# widget on someone's shop without a line of difference.
#
# The widget is mounted by the environment (see this directory's README):
#
#   INSIKA_WIDGET_ORIGINS=http://127.0.0.1:8080 \
#   INSIKA_WIDGET_AGENTS=support \
#   DEEPSEEK_API_KEY=sk-... ruby examples/web-widget/support_agent.rb
require_relative "../../lib/insika"

support = Insika.agent("support") do
  model "deepseek-v4-flash"
  provider :deepseek
  instructions <<~PROMPT
    You answer customers of an online shop, on a chat widget on its website.
    Reply in the customer's language, in one short and friendly message. If they
    mention an order number, confirm you will look into it and say what to expect.
  PROMPT

  # The one thing the widget REQUIRES of an agent it publishes. A public endpoint
  # with an LLM behind it and no ceiling is an unmetered bill, so the channel
  # answers 503 until this exists here or as a platform default. Six turns a minute
  # per visitor is plenty for a person and useless for a script.
  limits chat_rate_limit: 6
end

support.serve(port: 9494)
