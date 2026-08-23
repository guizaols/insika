# frozen_string_literal: true

module Insika
  module Router
    # Session-key extraction, matched to the routes that
    # actually carry production traffic in `Server::App` today. The RFC's own
    # sketch of a path-based `/api/widget/sessions/:token/…` route was written
    # from memory and does not match what `server/app.rb` implements — the
    # widget/relay surface is `POST /channels/:id/messages` (and `/events`),
    # with the session id as `session_id` in the JSON body, not a path
    # segment. `/v1/responses` and `/v1/messages` carry it as `user`. Every
    # other route (health checks, `/studio/*`, onboarding) has no session key
    # and round-robins — none of them depend on a worker's in-memory
    # `SessionActor` (§3.1 point 3).
    module SessionKey
      BODY_FIELD_BY_ROUTE = {
        %w[v1 responses] => "user",
        %w[v1 messages] => "user"
      }.freeze

      module_function

      # segments: the request path split on "/" with empty parts removed.
      # body: a zero-arg callable returning the parsed JSON body (a Hash) —
      # called AT MOST ONCE, and only when a route that carries a session key
      # actually matches, so a GET or an unrelated POST never pays for a
      # parse. A malformed body yields no key (the backend's own parser is
      # what answers the client's 400/422), never a router-level error.
      def extract(method, segments, body:)
        return nil unless method == "POST"

        field =
          if segments.length == 3 && segments[0] == "channels" && %w[messages events].include?(segments[2])
            "session_id"
          else
            BODY_FIELD_BY_ROUTE[segments]
          end
        return nil unless field

        read_field(body, field)
      end

      def read_field(body, field)
        parsed = body.call
        return nil unless parsed.is_a?(Hash)

        value = parsed[field] || parsed[field.to_sym]
        Insika::Coercion.present?(value) ? value.to_s : nil
      rescue StandardError
        nil
      end
    end
  end
end
