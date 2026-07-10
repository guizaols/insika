# frozen_string_literal: true

require_relative "config/wiring"
require_relative "server/boot"

# Rode com Falcon (async/streaming de verdade):
#   bundle exec falcon serve -b http://0.0.0.0:9292
#
# O Boot executa plugins → stores → recovery ANTES do `run` — nenhum request é
# servido antes de o recovery terminar (doc 07 §4). O listen é o último passo e
# pertence ao Falcon (carrega este config.ru inteiro antes de aceitar conexões).
app = Harness::Server::Boot.new(Harness::Wiring).call

# Modo SERVING (L4): APÓS o recovery, os turnos passam a nascer filhos de um
# supervisor de vida-longa (não do fiber efêmero da request) e sobrevivem ao
# DISCONNECT do cliente. Vale por worker sob `falcon serve` — o supervisor é
# criado lazy no reactor de cada worker no 1º turno (boundary do reactor).
# (No SHUTDOWN gracioso do worker o reactor para e cancela os turnos em voo;
# como Async::Cancel < Exception não é capturado como falha, a task fica
# :running e o recovery do próximo boot a retoma — durável, não perdida.)
Harness::Wiring::EXECUTOR.supervised = true

run app
