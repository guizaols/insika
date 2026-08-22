# frozen_string_literal: true

module Insika
  # LIVE MCP tools — kills the McpToolIngestor snapshot.
  #
  # `entries` is CHEAP: it reads only McpStore#tools_cache (no I/O), the same
  # contract the ToolStore-backed dynamic entries already give
  # OverlayToolRegistry — Policy recomputes `candidate_tools` every turn, so
  # an unreachable MCP server must never add real latency there.
  #
  # `refresh` is the ONLY thing that talks to a server ahead of time: it
  # connects, lists live, and writes the result back to tools_cache (display/
  # doctor). Calling a tool never depends on that cache — Insika::McpLiveTool
  # always goes through the live, memoized client (and RubyLLM::MCP::Client
  # does its own real `tools/list` on ITS first use per instance, regardless
  # of whether `refresh` ever ran).
  class McpToolRegistry
    def initialize(mcp_store:, client_factory: Insika::McpClient.method(:for))
      @mcp_store = mcp_store
      @client_factory = client_factory
      @clients = {}
      @mutex = Mutex.new
    end

    # -> [Registry::Entry] one per cached tool of every ENABLED instance.
    def entries
      @mcp_store.all_raw.select { |r| r["enabled"] }.flat_map { |r| entries_for(r) }
    end

    # Connects to `name` LIVE, lists its tools, and writes McpStore#tools_cache.
    # ALWAYS drops any memoized client first and rebuilds from the current
    # record: a stdio process can be `alive?` (still running) yet permanently
    # broken (e.g. wrong transport args — see grafana-stg gotcha), and an
    # edited command/url/env must take effect without a process restart —
    # there's no SSH into a Railway dyno to do that by hand.
    # -> the discovered [{"name","description","inputSchema"}]. Raises on a
    # missing/disabled instance or a transport failure — the caller (a CLI
    # verb/API route/UI button, PR3/PR4) decides how to surface it.
    def refresh(name)
      record = @mcp_store.get_raw(name.to_s)
      raise Insika::NotFoundError, "MCP instance '#{name}' not found" if record.nil?
      raise Insika::ValidationError, "MCP instance '#{name}' is disabled" unless record["enabled"]

      evict(record["name"])
      client = client_for(record)
      discovered = client.tools.map { |t| { "name" => t.name, "description" => t.description, "inputSchema" => t.params_schema } }
      @mcp_store.set_tools_cache(name, discovered)
      discovered
    end

    # Stops and drops any memoized client for `name` (no-op if none), so the
    # next `client_for` builds a fresh one off the current record. Public:
    # called by `refresh` above AND by UpsertMcp/DeleteMcp right after they
    # write the store — a Studio/CLI edit takes effect on that instance's
    # NEXT tool call or refresh, no process restart required (there's no way
    # to restart a process by hand on a Railway dyno).
    def evict(name)
      client = @mutex.synchronize { @clients.delete(name.to_s) }
      client&.stop
    rescue StandardError
      nil # best-effort teardown of a possibly already-dead process
    end

    private

    def entries_for(record)
      Array(record["tools_cache"]).map { |tool| entry_for(record, tool) }
    end

    def entry_for(record, tool)
      instance = record["name"]
      Insika::Registry::Entry.new(
        name: tool["name"], plugin: "mcp:#{instance}",
        metadata: { optional: false, side_effect: true, group: "mcp:#{instance}", tags: [] },
        factory: -> { build_tool(record, tool) }
      )
    end

    # Lazy require (McpLiveTool < RubyLLM::Tool pulls in ruby_llm) — kept out
    # of insika.rb load-time, loaded on the 1st instance (turn time), same
    # discipline as OverlayToolRegistry#build_tool for data-tools.
    def build_tool(record, tool)
      require_relative "mcp_live_tool"
      Insika::McpLiveTool.new(instance_name: record["name"], tool: tool, client_for: -> { client_for(record) })
    end

    # A started, MEMOIZED client for `record` — one real connection per
    # instance name, reused across calls/turns. Raises on a gated/unreachable
    # instance; only called from `refresh` and from a running McpLiveTool's
    # `#execute` (which rescues) — never from `entries`/`build_tool`, so a
    # downed server never breaks turn ASSEMBLY, only that tool's own call.
    def client_for(record)
      @mutex.synchronize do
        client = (@clients[record["name"]] ||= @client_factory.call(record))
        client.start unless client.alive?
        client
      end
    end
  end
end
