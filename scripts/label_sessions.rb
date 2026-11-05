# frozen_string_literal: true

# Gives migrated conversations the customer's name and phone, so the Studio
# shows a name instead of "anonymous". Conversations seeded from OpenClaw
# (migrate_openclaw.rb seed) carry no labels; a live turn sets them only when
# the customer writes again.
#
# Input on STDIN: JSON { "<chat id>": { "customer_name": "...", "customer_phone": "..." } }.
# The session id is the chat id, optionally prefixed by a tenant ("<tenant>:<chat id>").
# Only sessions with no customer_name are touched (of every agent, or of
# <agent-id> when given); a label a live turn already wrote is kept, and the
# session keeps its place in the list. --dry-run counts without writing.
#
# --ids prints the chat ids still unnamed (a JSON array), so the platform
# exports names only for the chats Insika has.
#
#   INSIKA_DB=/data/insika.db bundle exec ruby scripts/label_sessions.rb [agent-id] --ids > ids.json
#   INSIKA_DB=/data/insika.db bundle exec ruby scripts/label_sessions.rb [agent-id] [--dry-run] < map.json
require "json"
require_relative "../lib/insika"

module LabelSessions
  module_function

  def unnamed(sessions, agent)
    sessions.all_stats.select do |stat|
      vars = stat.vars || {}
      (agent.nil? || vars["agent"] == agent) && vars["customer_name"].to_s.strip.empty?
    end
  end

  def ids(sessions, agent) = unnamed(sessions, agent).map { |stat| stat.id.split(":").last }.uniq

  def run(sessions, agent, map, dry_run: false)
    labeled = 0
    unnamed(sessions, agent).each do |stat|
      labels = (map[stat.id.split(":").last] || {}).slice(*Insika::SessionStore::CUSTOMER_LABELS)
      labels = labels.reject { |_, v| v.to_s.strip.empty? }
      next if labels.empty?

      sessions.update_vars(stat.id, labels, amend: true) unless dry_run
      labeled += 1
    end
    labeled
  end
end

if $PROGRAM_NAME == __FILE__
  dry_run = ARGV.delete("--dry-run")
  list_ids = ARGV.delete("--ids")
  agent = ARGV.first
  sessions = Insika::SessionStore.new(store: Insika::Wiring::Graph.raw_backend_from_env)
  if list_ids
    puts LabelSessions.ids(sessions, agent).to_json
    exit
  end
  n = LabelSessions.run(sessions, agent, JSON.parse($stdin.read), dry_run: dry_run)
  puts "#{dry_run ? 'would label' : 'labeled'} #{n} sessions#{" of #{agent}" if agent}"
end
