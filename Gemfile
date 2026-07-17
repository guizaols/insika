# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2"

# D9 pinning (00-overview): the core (lib/) does not require ruby_llm at load-time
# (lazy require in the Executor/LoadSkill — spec/harness/load_guard_spec covers it),
# but the gem is now ALWAYS in the bundle. The "harness-server only" comments
# document the boundary of the future gem split.
gem "ruby_llm", ">= 1.15"  # before_tool_call/after_tool_result require 1.15+
gem "async", "~> 2.0"      # core (reactor, SQLite write semaphore)
gem "falcon", "~> 0.55"    # async server (harness-server only)
gem "sqlite3", "~> 2.0"    # SQLite backend only
gem "rack", "~> 3.0"       # transport (harness-server only)

# Studio (Phase 4 — management UI). FRAMEWORK AT THE EDGE: used ONLY by the `studio/`
# app (thin tree router under Falcon, no ActiveRecord); `lib/harness` and `server/`
# do NOT depend on Roda. tilt+erubi render the ERB templates with automatic escaping.
gem "roda", "~> 3.85"      # harness-studio only
gem "tilt", "~> 2.8"       # template rendering (studio)
gem "erubi", "~> 1.13"     # ERB with automatic escaping (XSS-safe) for the studio

# OPT-IN observability (Phase 6, Telemetry): OTEL is only REQUIRED lazily in
# Harness::Telemetry.setup when enabled (HARNESS_OTEL / OTEL_EXPORTER_OTLP_*).
# Off -> gems in the bundle but never loaded (parity, zero overhead). The
# Recorder is tested with an injected FAKE tracer; the gem only enters at the setup
# boundary (not covered by unit, like the Executor's create_chat).
gem "opentelemetry-sdk", "~> 1.10"          # harness-server only
gem "opentelemetry-exporter-otlp", "~> 0.31" # OTLP exporter (SigNoz/Tempo/etc.)

group :development, :test do
  gem "rspec"
end
