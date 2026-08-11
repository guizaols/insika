# frozen_string_literal: true

source "https://rubygems.org"

# Recommended/tested runtime is pinned in `.ruby-version` (3.4.x) and shipped by
# the Dockerfile; YJIT is enabled in production via RUBY_YJIT_ENABLE=1. The floor
# lives in the gemspec (>= 3.3) so the gem can be consumed on older interpreters.
# See docs/BENCHMARKS.md for the Ruby-version × YJIT matrix behind the default.
ruby ">= 3.3"

# The runtime dependencies are the gemspec's: the gem and the
# reference deployment share ONE dependency list. The rule still holds —
# `require "insika"` loads neither ruby_llm nor the HTTP surface; both are
# required lazily (spec/insika/load_guard_spec.rb is the guard).
gemspec

# OPT-IN observability (Telemetry): OTEL is only REQUIRED lazily in
# Insika::Telemetry.setup when enabled (INSIKA_OTEL / OTEL_EXPORTER_OTLP_*).
# These four are NOT gem dependencies — an adopter who wants OTel adds them,
# exactly like this deployment does. Off -> gems in the bundle but never loaded
# (parity, zero overhead). The Recorder is tested with an injected FAKE tracer.
gem "opentelemetry-sdk", "~> 1.10"
gem "opentelemetry-exporter-otlp", "~> 0.31" # OTLP exporter (SigNoz/Tempo/etc.)
# Metrics beside traces: counters/histograms so a backend charts
# volume/latency/tokens/cost without aggregating spans. Still 0.x upstream, so the
# require is guarded — absent from the bundle degrades to traces only.
gem "opentelemetry-metrics-sdk", "~> 0.15"
gem "opentelemetry-exporter-otlp-metrics", "~> 0.10"
