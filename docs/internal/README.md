# Internal / pilot material — not part of the OSS surface

Files here reference the **real OpenClaw pilot**: real merchant names, real measured
benchmark data, and glue that depends on the private `../openclaw/` workspace. They
are kept as-is (real data is not falsified), but gated out of the public OSS story —
an OSS user never needs them.

- **`BENCHMARKS.md`** — real p50/p95 measurements attributed to the actual pilot
  agents (`agent-store-*`). Renaming the tenants would falsify the results, so the
  file lives here instead.
- **`../scripts/internal/openclaw_to_*.rb`** — OpenClaw → harness pack/manifest
  converters. They mirror OpenClaw's runtime group derivation (merchant-prefix
  heuristics like `cacau_`/`natura_`), so the brand tokens are *functional*, not
  labels. Pilot-migration tooling; not needed to run the harness.

If/when the pilot references are no longer relevant, this whole directory can be
dropped without touching the OSS surface.
