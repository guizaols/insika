# Criterion — a frozen harvest conversion ruler (spec fixture)

> The real criterion is the deployment's own: the engine reads the file
> `INSIKA_HARVEST_CRITERION` points at. This fixture exists so the
> deployment wiring spec has a stable, public file to boot against.

```yaml
version: 1
metric: primary
window: 72h
threshold: 0.05
min_span: 28d
```