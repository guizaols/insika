# frozen_string_literal: true

# Smoke rackup contract (doc 07 §8): Boot has already run in boot_app and SMOKE_APP
# is ready (recovery BEFORE listen). The test uses serve.rb (single-process,
# controllable); this config.ru documents the `falcon serve`/rackup path.
require_relative "boot_app"

run SMOKE_APP
