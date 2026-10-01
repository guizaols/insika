# frozen_string_literal: true

# Copies every key of one Insika store into another, through the Store API only,
# so it works for any pair of backends. Run with the app stopped (nothing writing
# to the source), then point the app at the target.
#
#   INSIKA_DB=/data/insika.db INSIKA_DATABASE_URL=postgres://... bundle exec ruby scripts/store_copy.rb
require_relative "../lib/insika"

module Insika
  module StoreCopy
    module_function

    # -> number of keys copied. Writes `batch` keys per transaction on the target.
    def call(from:, to:, batch: 500, log: nil)
      copied = 0
      from.scopes.each do |scope|
        from.list(scope).each_slice(batch) do |keys|
          to.transaction { keys.each { |key| to.set(scope, key, from.get(scope, key)) } }
          copied += keys.size
        end
        log&.puts("#{scope}: done (#{copied} keys so far)")
      end
      copied
    end
  end
end

if $PROGRAM_NAME == __FILE__
  db = ENV.fetch("INSIKA_DB") { abort "INSIKA_DB (the SQLite source) is required" }
  url = ENV.fetch("INSIKA_DATABASE_URL") { abort "INSIKA_DATABASE_URL (the Postgres target) is required" }
  from = Insika::Stores::SQLite.new(path: db)
  to = Insika::Stores::Postgres.new(url: url)
  n = Insika::StoreCopy.call(from: from, to: to, log: $stdout)
  puts "copied #{n} keys from #{db} to Postgres"
end
