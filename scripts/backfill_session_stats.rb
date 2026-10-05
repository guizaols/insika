# frozen_string_literal: true

# Writes the stats record (last update, message count, agent) of every session
# stored before sessions kept them, so the Studio home counts those sessions too.
# Idempotent and safe with the app running: a session written meanwhile already
# writes its own stats. Uses the deployment's store (INSIKA_DB or
# INSIKA_DATABASE_URL), like the app.
#
#   INSIKA_DB=/data/insika.db bundle exec ruby scripts/backfill_session_stats.rb
require_relative "../lib/insika"

backend = Insika::Wiring::Graph.raw_backend_from_env
n = Insika::SessionStore.new(store: backend).backfill_stats
puts "wrote stats for #{n} sessions"
