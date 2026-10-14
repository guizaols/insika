---
title: Performance
parent: Operate
nav_order: 8
permalink: /performance/
---

# Performance

What the engine does to stay cheap per turn, and what was tried and left out. A turn
mostly waits on the model provider, so the engine's job is to add little CPU, hold
little memory and never block the other turns in the same process.

To measure your own load, see [Deploy › Measuring performance](DEPLOY.md#measuring-performance--load),
[Load test](LOADTEST.md) and the [Benchmark](BENCHMARK.md).

## Numbers you can reproduce

Each one comes from a script in this repository, with no API key and no real data.

| What | Number | Run |
|---|---|---|
| Engine work per turn, model stubbed | p50 ≈ 0.4 ms, ~1,700–1,900 turns/s per process | `bundle exec ruby scripts/bench.rb` ([Benchmark](BENCHMARK.md)) |
| SQLite writes, 1 to 8 processes on one file | ~25–30k writes/s in total, zero "database is locked" | `bundle exec ruby scripts/bench_store.rb 1,2,4,8 3000` ([Deploy](DEPLOY.md#1-sqlite-write-ceiling-no-provider--bench_storerb)) |
| One key lookup, `execute` vs a cached prepared statement | ~2.7 µs vs ~0.9 µs (Ruby 4.0, laptop) | the snippet below |

A turn makes a few hundred store calls at most. Saving ~2 µs on each is well under a
millisecond per turn, which is why statement caching is in the "left out" table.

```ruby
require "sqlite3"; require "benchmark"
db = SQLite3::Database.new(":memory:")
db.execute("CREATE TABLE kv (scope TEXT, key TEXT, value TEXT, PRIMARY KEY (scope, key))")
1000.times { |i| db.execute("INSERT INTO kv VALUES (?, ?, ?)", ["s", "k#{i}", "x" * 500]) }
sql = "SELECT value FROM kv WHERE scope = ? AND key = ?"
st = db.prepare(sql)
Benchmark.bm(9) do |b|
  b.report("execute")  { 200_000.times { |i| db.get_first_value(sql, ["s", "k#{i % 1000}"]) } }
  b.report("prepared") { 200_000.times { |i| st.reset!; st.bind_params("s", "k#{i % 1000}"); st.step } }
end
```

## What the engine does

**No Rails, no ORM.** The server is Falcon with Rack and Roda. The store is a key-value
table driven by the `sqlite3` gem directly. Nothing loads a framework or builds model
objects on the hot path.

**One fiber per turn.** Each turn runs as an `Async` task. While it waits on the provider,
a tool or the store, the same process runs other turns. One worker holds many concurrent
conversations without threads. See [Architecture](ARCHITECTURE.md).

**Session actors end when idle.** Turns of the same session run in order through a small
actor. Its loop ends as soon as its queue drains and it leaves the executor's table, so an
idle session holds no fiber.

**SQLite tuned for many writers.**

- WAL mode with `synchronous = NORMAL`.
- `busy_handler_timeout=` instead of `busy_timeout=`. The C-level handler sleeps while
  holding the GVL, so a worker waiting on another process's write lock would freeze every
  fiber it runs. The Ruby-level handler lets the scheduler keep the other turns going.
- **Group commit.** Writes that arrive while one is waiting for the lock join the same
  transaction and share one `COMMIT`. Each caller still returns only after its own write is
  committed, so durability and per-fiber order do not change. Fewer commits means less
  fighting over the file's single write lock when several workers share it.
- Prefix and recent-items reads are one range query, not one query per key.
- `INSIKA_SLOW_STORE_MS` logs every slow store call, and every slow group-commit batch with
  its time split into wait, statements and commit. A long wait with a short commit means
  another process holds the lock. A long commit means the batch itself is heavy.

**Memory goes back to the OS.**

- `MALLOC_ARENA_MAX=2` caps glibc's malloc arenas. Under a multi-worker load, the peak
  stays lower with the same latency.
- `MALLOC_MMAP_THRESHOLD_=131072` pins the mmap threshold. Large buffers stay mmapped and
  return to the OS when freed instead of fragmenting the arenas.
- `Insika::MemoryTrim` runs on a quiet worker: no turn in flight and enough allocated since
  the last pass. It runs a full GC and then `malloc_trim(0)`. Without it, a worker stays at
  its peak after a burst, because a GC alone gives nothing back to the OS. It needs the
  `fiddle` gem and does nothing where `malloc_trim` does not exist (macOS, musl).
- Long-lived fibers return `nil` from their blocks, so a finished task's result is not kept
  alive by a stale reference.

**YJIT on.** The reference image sets `RUBY_YJIT_ENABLE=1`. It lowers CPU per turn
(serialization, streaming, context building) for a small memory cost per worker.

**Workers are a contract input, not a tuning knob.** More worker processes means more
memory and more writers on one SQLite file. Start with one. Add workers, and the
[Router](ROUTER.md) in front of them, only when one process's CPU is the limit. See
[Deploy › The process model](DEPLOY.md#the-process-model).

## Tried and left out

Each of these was measured on a production-like load and did not pay off. Measure again
before you reopen one.

| Idea | Why it is out |
|---|---|
| jemalloc or mimalloc instead of glibc | `MALLOC_ARENA_MAX` plus `MemoryTrim` already got most of the gain. Both left a higher memory floor after repeated loads, and `malloc_trim` does nothing under them. |
| Preforking workers from a parent with the code loaded (copy-on-write) | Saves memory only right after boot. After a load, each worker's floor is its own heap, not duplicated code. |
| `GC.compact` during the trim | Fewer heap pages, same RSS. |
| Async HTTP adapter for the provider | Slower end to end than plain `Net::HTTP`, and it breaks Streamable-HTTP MCP outside an Async reactor. |
| Write-behind for traces, compressing large stored values | No measurable gain over group commit. Old compressed rows are still read. |
| Postgres store for speed on one box | Every store call becomes a network round trip, and a turn makes many store calls. Use it to share the store across nodes, not for speed. See [Deploy › Postgres store](DEPLOY.md#postgres-store-optional). |
| Caching prepared SQLite statements | Saves microseconds per call. Too small next to a turn that waits on the provider. |

Once group commit is in place, writer contention on one SQLite file under sustained heavy
load is a matter of architecture: fewer writer processes, a faster volume, or a shared
store. More application-level tuning does not move it.
