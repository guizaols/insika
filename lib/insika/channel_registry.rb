# frozen_string_literal: true

module Insika
  # The channels this deployment speaks, by id. A `Registry` like
  # tools and workflows — same plugin bookkeeping, so `deregister_plugin` rolls a
  # half-registered plugin back exactly as it does for a tool.
  #
  # The id is the URL segment (`/channels/relay/events`), which is why lookup here
  # is a `find` and not a `resolve`: an unknown segment is a 404, not an exception
  # the transport has to rescue.
  class ChannelRegistry < Registry
    # -> the channel instance | nil (unknown id). A blank id never matches.
    def find(id)
      name = id.to_s
      return nil if name.empty?

      resolve(name)
    rescue Insika::NotFoundError
      nil
    end

    # Does this channel deliver out of band (Shape B)? A Shape A channel answers on
    # the request's own stream and has no `deliver`, so nothing is ever written to
    # the outbox for it. Duck-typed, like every other seam in the engine.
    def deliverable?(id)
      channel = find(id)
      !channel.nil? && channel.respond_to?(:deliver)
    end
  end
end
