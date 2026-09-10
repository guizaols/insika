# frozen_string_literal: true

require_relative "server"

seed = ENV["STORE_SEED"] || File.expand_path("../seed/store.json", __dir__)
run BenchStore::App.new(BenchStore::State.new(seed))
