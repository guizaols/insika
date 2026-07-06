# frozen_string_literal: true

require_relative "app/server"

# Rode com Falcon (async/streaming de verdade):
#   bundle exec falcon serve -b http://0.0.0.0:9292
run APP
