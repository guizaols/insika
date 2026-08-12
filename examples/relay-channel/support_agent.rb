# frozen_string_literal: true

# The ENGINE side of the relay example. Deliberately an ordinary agent — nothing
# here knows a channel exists. That is the point: a channel is an edge, not a
# property of the agent, so the same agent serves /v1/responses, the Studio and
# WhatsApp-through-your-own-stack without a line of difference.
#
# The relay is mounted by the environment (see this directory's README):
#
#   INSIKA_RELAY_TOKEN=dev-inbound-secret \
#   INSIKA_RELAY_DELIVER_URL=http://127.0.0.1:4000 \
#   INSIKA_EGRESS_ALLOW_HTTP=1 INSIKA_EGRESS_ALLOW_PRIVATE=1 \
#   DEEPSEEK_API_KEY=sk-... ruby examples/relay-channel/support_agent.rb
require_relative "../../lib/insika"

support = Insika.agent("support") do
  model "deepseek-v4-flash"
  provider :deepseek
  instructions <<~PROMPT
    Você atende clientes de uma loja pelo WhatsApp. Responda em português, em uma
    mensagem curta e cordial. Se o cliente citar um número de pedido, confirme que
    vai verificar e diga o que ele deve esperar.
  PROMPT
end

support.serve
