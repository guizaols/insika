# frozen_string_literal: true

# The CONSUMER side of a relay channel — your messaging stack, in 20 lines.
#
# In real life this is the code that already talks to WhatsApp/Slack/your app. Here
# it just prints, so you can watch the contract work:
#
#   run it:  bundle exec falcon serve --bind http://127.0.0.1:4000 \
#              --config examples/relay-channel/consumer.ru
#
# Then point the engine at it with INSIKA_RELAY_DELIVER_URL. See the README.

require "json"

DELIVER_TOKEN = ENV["INSIKA_RELAY_DELIVER_TOKEN"]

run lambda { |env|
  # Same discipline as the engine's own edge: check the credential first, always.
  if DELIVER_TOKEN && env["HTTP_AUTHORIZATION"] != "Bearer #{DELIVER_TOKEN}"
    next [401, { "content-type" => "application/json" }, ['{"error":"unauthorized"}']]
  end

  body = JSON.parse(env["rack.input"].read)

  # `X-Insika-Delivery` is a stable idempotency key. Delivery is at-most-once, so
  # you will not normally see a repeat — but if a retry lands after a timeout that
  # actually succeeded, this is what lets you drop the second copy.
  puts "→ delivery #{env['HTTP_X_INSIKA_DELIVERY']} for #{body['external_id']}"

  # progressive: when `index`/`final` are present this POST is one
  # balloon of several for the same `task_id` — send it as its OWN platform
  # message, in arrival order (which is index order). The consumer that only
  # forwards `content` and ignores these keys still works.
  if body["index"]
    puts "  balloon #{body['index']}#{body['final'] ? ' (final)' : ''} → #{body['content']}"
  else
    puts "  #{body['content']}"
  end

  # This is where you would hand `content` to the platform: send_whatsapp_message(
  # body["external_id"], body["content"]). Anything 2xx tells the engine it landed.
  [200, { "content-type" => "application/json" }, ["{}"]]
}
