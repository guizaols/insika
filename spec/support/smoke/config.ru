# frozen_string_literal: true

# Contrato rackup do smoke (doc 07 §8): o Boot já rodou no boot_app e SMOKE_APP
# está pronto (recovery ANTES do listen). O teste usa serve.rb (single-process,
# controlável); este config.ru documenta o caminho `falcon serve`/rackup.
require_relative "boot_app"

run SMOKE_APP
