# frozen_string_literal: true

source "https://rubygems.org"

# Recommended/tested runtime is pinned in `.ruby-version` (3.4.x) and shipped by
# the Dockerfile; YJIT is enabled in production via RUBY_YJIT_ENABLE=1. The floor
# stays permissive so the (future) gem can be consumed on older interpreters —
# 3.2 is EOL, so 3.3 is the minimum. See docs/BENCHMARKS.md for the Ruby-version ×
# YJIT matrix (3.3.5 vs 4.0.6) behind the 4.0.6 default choice (FOLLOWUP §1.1).
ruby ">= 3.3"

# D9 pinning (00-overview): the core (lib/) does not require ruby_llm at load-time
# (lazy require in the Executor/LoadSkill — spec/insika/load_guard_spec covers it),
# but the gem is now ALWAYS in the bundle. The "insika-server only" comments
# document the boundary of the future gem split.
gem "ruby_llm", ">= 1.15"  # before_tool_call/after_tool_result require 1.15+
gem "async", "~> 2.0"      # core (reactor, SQLite write semaphore)
gem "falcon", "~> 0.55"    # async server (insika-server only)
gem "sqlite3", "~> 2.0"    # SQLite backend only
gem "rack", "~> 3.0"       # transport (insika-server only)

# Studio (Phase 4 — management UI). FRAMEWORK AT THE EDGE: used ONLY by the `studio/`
# app (thin tree router under Falcon, no ActiveRecord); `lib/insika` and `server/`
# do NOT depend on Roda. tilt+erubi render the ERB templates with automatic escaping.
gem "roda", "~> 3.85"      # insika-studio only
gem "tilt", "~> 2.8"       # template rendering (studio)
gem "erubi", "~> 1.13"     # ERB with automatic escaping (XSS-safe) for the studio

# OPT-IN observability (Phase 6, Telemetry): OTEL is only REQUIRED lazily in
# Insika::Telemetry.setup when enabled (INSIKA_OTEL / OTEL_EXPORTER_OTLP_*).
# Off -> gems in the bundle but never loaded (parity, zero overhead). The
# Recorder is tested with an injected FAKE tracer; the gem only enters at the setup
# boundary (not covered by unit, like the Executor's create_chat).
gem "opentelemetry-sdk", "~> 1.10"          # insika-server only
gem "opentelemetry-exporter-otlp", "~> 0.31" # OTLP exporter (SigNoz/Tempo/etc.)
# Metrics beside traces (item 16 / P4): counters/histograms so a backend charts
# volume/latency/tokens/cost without aggregating spans. Still 0.x upstream, so the
# require is guarded — absent from the bundle degrades to traces only.
gem "opentelemetry-metrics-sdk", "~> 0.15"
gem "opentelemetry-exporter-otlp-metrics", "~> 0.10"

group :development, :test do
  gem "rspec"
end
