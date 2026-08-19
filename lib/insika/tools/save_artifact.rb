# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # `save_artifact` — the agent delivers a page (a report, a digest) to a
    # destination that survives the channel: title + content in, a URL out,
    # which it can include in a channel message ("today's report: <url>").
    #
    # A REGISTRY tool (not a ChatBuilder system tool): the per-agent
    # `tools_allow` is the switch — registered `optional: true`, so an agent
    # that did not name it cannot call it, and nothing global enables it.
    # The bindings (tenant, agent, task) are the tool INSTANCE's, deposited
    # by the Executor into `turn_context` like a data-tool's — never
    # parameters the model types.
    class SaveArtifact < RubyLLM::Tool
      description "Save an HTML (or markdown / SVG) page — a report, a digest, " \
                  "a summary — and get back a URL to share. Use when the answer " \
                  "is a document the channel message cannot carry."
      param :title, desc: "Short human-readable title (<= 200 chars)"
      param :content, desc: "The page content: HTML with inline SVG for charts, " \
                            "markdown, or SVG. No scripts, no external resources."
      param :mime, desc: "text/html (default), text/markdown, or image/svg+xml",
                   required: false

      def name = "save_artifact"

      def initialize(artifact_store:, base_url: nil, signing_key: nil, signing_ttl: nil,
                     max_bytes: nil, event_stream: nil)
        @artifact_store = artifact_store
        @base_url = base_url.to_s.sub(%r{/\z}, "")
        @signing_key = signing_key
        @signing_ttl = signing_ttl
        @max_bytes = max_bytes
        @event_stream = event_stream
        super()
      end

      # Per-turn bindings, deposited by the Executor (ToolAssembly's
      # `turn_context=` seam — the same one data-tools use). From the TURN,
      # never from the model (the tenant-lesson: an id the model types is
      # inventable, and the turn looks right anyway).
      attr_reader :turn_context

      def turn_context=(ctx)
        @turn_context = (ctx || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      def execute(title:, content:, mime: "text/html")
        # the deployment's size cap rides the tool instance (INSIKA_ARTIFACT_
        # MAX_BYTES at wiring); absent -> the store's default.
        attrs = { tenant: binding_tenant, agent: @turn_context&.dig(:agent_id),
                  task_id: @turn_context&.dig(:task_id), title: title, mime: mime,
                  content: content }
        attrs[:max_bytes] = @max_bytes if @max_bytes
        record = @artifact_store.create(**attrs)
        # the authenticated Studio URL is the always-on answer; the signed
        # link exists ONLY when a key was configured (it shares OUTSIDE the
        # Studio and expires).
        url = Insika::ArtifactSigning.url_for(id: record.id, base: @base_url)
        result = { id: record.id, url: url }
        signed = Insika::ArtifactSigning.url_for(
          id: record.id, base: @base_url, key: @signing_key, ttl: @signing_ttl
        )
        result[:signed_url] = signed if signed != url
        emit(record)
        result
      rescue Insika::ValidationError => e
        { error: e.message }
      end

      private

      # The tenant is the AGENT's tenant: the declared command tenant, or the
      # deployment's "platform" in single-tenant — never the chat id (a report
      # belongs to the agent, not to whichever chat ran it), never a parameter
      # the model types.
      def binding_tenant
        declared = @turn_context&.dig(:command_tenant).to_s
        declared.empty? ? "platform" : declared
      end

      # :artifact_saved carries ids + title — NEVER the content (a report is
      # customer data that rides the store, not the events).
      def emit(record)
        @event_stream&.emit(Insika::Event.new(
                              type: :artifact_saved,
                              data: { id: record.id, title: record.title },
                              meta: { task_id: @turn_context&.dig(:task_id) }
                            ))
      end
    end
  end
end