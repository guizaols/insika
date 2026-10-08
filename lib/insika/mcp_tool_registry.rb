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
  # always goes through the live, memoized client (and RubyLLM::MCP
  # does its own real `tools/list` on ITS first use per instance, regardless
  # of whether `refresh` ever ran).
  class McpToolRegistry
    # Providers reject a tool name longer than this.
    MAX_TOOL_NAME = 64

    # The name the model and the agent's allowlist see: the instance, then the
    # server's tool. Two servers offering the same tool (a store's prod and
    # staging) stay two tools, each reaching its own instance.
    def self.tool_name(instance, tool)
      "#{instance.to_s.downcase.gsub(/[^a-z0-9]+/, '_')}__#{tool}"
    end

    # Live clients kept per process. Past this, the least recently used one is
    # closed; its conversation reconnects on its next call, as a NEW MCP session.
    # ponytail: count cap, not idle TTL — add a TTL if idle sockets pile up.
    MAX_CLIENTS = 200

    def initialize(mcp_store:, client_factory: Insika::McpClient.method(:for), max_clients: MAX_CLIENTS)
      @mcp_store = mcp_store
      @client_factory = client_factory
      @max_clients = max_clients
      @clients = {} # [instance, conversation] -> client, oldest use first
      @mutex = Mutex.new
    end

    # -> [Registry::Entry] one per cached tool of every ENABLED instance.
    def entries
      @mcp_store.all_raw.select { |r| r["enabled"] }.flat_map { |r| entries_for(r) }
    end

    # Connects to `name` LIVE, lists its tools, and writes McpStore#tools_cache.
    # ALWAYS drops any memoized client first and rebuilds from the current
    # record: a stdio process can still be running yet permanently
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
      discovered = client.tools.map do |tool|
        { "name" => tool.name, "description" => tool.description, "inputSchema" => tool.parameters_schema,
          "annotations" => { "readOnlyHint" => tool.read_only? } }
      end
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
      gone = @mutex.synchronize do
        keys = @clients.keys.select { |instance, _| instance == name.to_s }
        keys.map { |key| @clients.delete(key) }
      end
      gone.each { |client| close_quietly(client) }
    end

    private

    def entries_for(record)
      Array(record["tools_cache"]).filter_map do |tool|
        name = self.class.tool_name(record["name"], tool["name"])
        next entry_for(record, tool, name) if name.length <= MAX_TOOL_NAME

        warn "[mcp] skipping '#{name}': longer than #{MAX_TOOL_NAME} characters; shorten the instance name"
      end
    end

    def entry_for(record, tool, name)
      instance = record["name"]
      Insika::Registry::Entry.new(
        name: name, plugin: "mcp:#{instance}",
        metadata: { optional: false, side_effect: !read_only?(tool), group: "mcp:#{instance}", tags: [] },
        factory: -> { build_tool(record, tool, name) }
      )
    end

    # An MCP tool is a side effect unless its server says otherwise
    # (`annotations.readOnlyHint`): a write is never re-run on resume and runs
    # serially within the session; a declared read keeps `tool_concurrency`.
    def read_only?(tool)
      tool.dig("annotations", "readOnlyHint") == true
    end

    # Lazy require (McpLiveTool < RubyLLM::Tool pulls in ruby_llm) — kept out
    # of insika.rb load-time, loaded on the 1st instance (turn time), same
    # discipline as OverlayToolRegistry#build_tool for data-tools.
    def build_tool(record, tool, name)
      require_relative "mcp_live_tool"
      Insika::McpLiveTool.new(instance_name: record["name"], tool: tool, name: name,
                              overrides: record.dig("tool_overrides", tool["name"]) || {},
                              client_for: ->(session_id = nil) { client_for(record, session_id) })
    end

    # A lazy, MEMOIZED client for `record` — one per (instance, conversation),
    # reused across that conversation's turns. The server ties its state to the
    # MCP session (Mcp-Session-Id): a client shared by every conversation leaked
    # one chat's target store and confirmation tokens into another. A stdio
    # instance stays one shared process — a process per chat is too costly.
    # Raises on a gated/unreachable instance; only called from `refresh` and
    # from a running McpLiveTool's `#execute` (which rescues) — never from
    # `entries`/`build_tool`, so a downed server never breaks turn ASSEMBLY,
    # only that tool's own call.
    def client_for(record, session_id = nil)
      session_id = nil if record["transport"].to_s == "stdio"
      key = [record["name"], session_id&.to_s]
      stale = nil
      client = @mutex.synchronize do
        found = @clients.delete(key) || @client_factory.call(record)
        @clients[key] = found # re-insert: most recently used goes last
        stale = @clients.shift.last if @clients.size > @max_clients
        found
      end
      close_quietly(stale) if stale
      client
    end

    def close_quietly(client)
      client.close
    rescue StandardError
      nil # best-effort teardown of a possibly already-dead process
    end
  end
end
