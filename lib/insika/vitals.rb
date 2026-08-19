# frozen_string_literal: true

module Insika
  # Process vitals. One cheap read-only answer to "which process
  # is this, how long has it been up, how much memory does it hold, and what is
  # the Ruby heap doing?" It touches NO store, allocates nothing meaningful,
  # and knows nothing about soaks — a general operator surface the soak
  # happens to be the first consumer of. Exposed at GET /v1/vitals (operator
  # only).
  module Vitals
    # Stamped when this file is first required: the process's own start, which
    # is what "uptime" has to mean (Falcon's controller start is not this
    # worker's). Per-process, not per-App, so a worker respawn under a live
    # container keeps its real age and a new pid reads as a new clock.
    STARTED_AT = Time.now.utc

    # The subset of GC.stat that answers "is the Ruby heap growing, or is this
    # the allocator?" — the difference between a leak and fragmentation, which
    # is the first fork of any leak hunt .
    GC_KEYS = %i[heap_live_slots heap_free_slots heap_allocated_pages
                 total_allocated_objects total_freed_objects
                 major_gc_count minor_gc_count
                 malloc_increase_bytes oldmalloc_increase_bytes].freeze

    module_function

    # -> Hash with STRING keys (it is a JSON body, not an internal value
    # object). `executor:`/`db_path:` are optional — absent, the body simply
    # omits those readings. `env:` is injected for specs.
    def snapshot(executor: nil, db_path: nil, env: ENV)
      {
        "boot_id" => EnvSchema.read("INSIKA_BOOT_ID", env).to_s,
        "pid" => Process.pid,
        "started_at" => STARTED_AT.iso8601,
        "uptime_s" => (Time.now.utc - STARTED_AT).round,
        "version" => Insika::VERSION,
        "ruby" => RUBY_DESCRIPTION,
        "yjit" => (defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?),
        "rss_bytes" => rss_bytes,
        "gc" => gc_stat,
        "threads" => Thread.list.size,
        "in_flight" => executor&.in_flight&.size,
        "db_bytes" => db_bytes(db_path),
        "at" => Time.now.utc.iso8601
      }
    end

    # Resident set size in bytes. Linux first (/proc/self/status VmRSS) —
    # production is a Linux container; macOS/dev fall back to `ps`. Neither
    # readable -> nil, NEVER a guess: a fabricated RSS would silently pass an
    # envelope.
    def rss_bytes
      if File.file?("/proc/self/status")
        match = File.read("/proc/self/status", encoding: "ASCII-8BIT")[/^VmRSS:\s+(\d+)\s*kB/, 1]
        return Integer(match) * 1024 if match
      end

      out = `ps -o rss= -p #{Process.pid} 2>/dev/null`.strip
      return Integer(out) * 1024 unless out.empty?

      nil
    rescue StandardError
      nil
    end

    def gc_stat
      stat = GC.stat
      GC_KEYS.each_with_object({}) { |key, acc| acc[key.to_s] = stat[key] }
    end

    # SQLite file + WAL + shm bytes. -> { "db" =>, "wal" =>, "shm" => } | nil.
    def db_bytes(path)
      return nil if path.nil? || path.to_s.empty?

      {
        "db" => File.size(path.to_s),
        "wal" => File.exist?("#{path}-wal") ? File.size("#{path}-wal") : 0,
        "shm" => File.exist?("#{path}-shm") ? File.size("#{path}-shm") : 0
      }
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
      nil
    end
  end
end
