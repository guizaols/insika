# frozen_string_literal: true

# Sends ONE inbound message the way your messaging stack would, and prints the ack.
#
#   ruby examples/relay-channel/send.rb "queria saber do pedido"
#
# The whole point of this file is the ack table: a 202 means the reply is coming to
# your callback and is yours to deliver; a 200 means it is NOT.

require "json"
require "net/http"
require "uri"
require "securerandom"

ENGINE  = ENV.fetch("INSIKA_URL", "http://127.0.0.1:9292")
TOKEN   = ENV.fetch("INSIKA_RELAY_TOKEN")
AGENT   = ENV.fetch("AGENT", "support")
CUSTOMER = ENV.fetch("EXTERNAL_ID", "5511999998888")

uri = URI.parse("#{ENGINE}/channels/relay/events")
request = Net::HTTP::Post.new(uri)
request["authorization"] = "Bearer #{TOKEN}"
request["content-type"] = "application/json"
request.body = JSON.generate(
  agent: AGENT,
  external_id: CUSTOMER,
  message: ARGV.join(" "),
  # Your own id for this event. Send it and a retry costs you nothing; omit it and
  # every retry is a second turn you pay for and a second message the customer reads.
  event_id: ENV["EVENT_ID"] || SecureRandom.uuid,
  vars: { "locale" => "pt-BR" }
)

response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
body = JSON.parse(response.body) rescue { "raw" => response.body } # rubocop:disable Style/RescueModifier

puts "#{response.code} #{JSON.generate(body)}"
puts(
  case response.code.to_i
  when 202 then "→ a turn is running; its answer will be POSTed to your deliver_url."
  when 200 then "→ this call owns NO reply (#{(body.keys - %w[task_id]).join(', ')}). " \
                "Deliver nothing — the answer belongs to task #{body['task_id']}."
  when 401 then "→ wrong INSIKA_RELAY_TOKEN."
  when 404 then "→ the relay is not mounted: the engine has no INSIKA_RELAY_TOKEN set."
  when 503 then "→ the channel is mounted but has no credential configured."
  else "→ see the error above."
  end
)
