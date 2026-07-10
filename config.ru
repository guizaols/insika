# frozen_string_literal: true

require_relative "config/wiring"
require_relative "server/boot"

# Rode com Falcon (async/streaming de verdade):
#   bundle exec falcon serve -b http://0.0.0.0:9292
#
# O Boot executa plugins → stores → recovery ANTES do `run` — nenhum request é
# servido antes de o recovery terminar (doc 07 §4). O listen é o último passo e
# pertence ao Falcon (carrega este config.ru inteiro antes de aceitar conexões).
run Harness::Server::Boot.new(Harness::Wiring).call
