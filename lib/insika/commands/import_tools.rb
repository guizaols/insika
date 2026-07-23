# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # BATCH ingestion of data-tools from a manifest (Phase 7, Step B).
    # Normalizes each tool (defaults + envelope adapter + endpoint→url + secret/
    # env) via ToolManifest, UPSERTs it into the ToolStore, and RELOADS the overlay +
    # catalog ONCE at the end — takes effect without a restart (NF3). Idempotent
    # (re-importing reconciles). Injects the deployment's `{{secret.*}}`/`{{env.*}}`
    # resolvers (D6/open-q2): the secret NEVER comes in the manifest.
    #
    # ISOLATED PARTIAL FAILURE (R4): a malformed tool (invalid envelope, missing
    # endpoint, unconfigured secret, collision with a code tool, invalid url)
    # does NOT bring down the batch — it becomes an entry in `errors[]`. Only a STRUCTURAL error in the
    # manifest (defaults/tools of the wrong type) raises (transport -> 422).
    # Per-tool report in the shape of the Phase 6 pack importer.
    #   -> { version, created: [names], updated: [names], errors: [{tool,error}] }
    class ImportTools
      def initialize(tool_store:, registry:, tool_catalog:, event_stream:, secrets: ENV, env: ENV)
        @tool_store = tool_store
        @registry = registry
        @tool_catalog = tool_catalog
        @event_stream = event_stream
        @secrets = secrets
        @env = env
      end

      def call(command)
        manifest = Insika::ToolManifest.from_h(command.payload) # structural -> 422
        report = { version: manifest.version, created: [], updated: [], errors: [] }

        manifest.tools.each_with_index do |raw, i|
          import_one(manifest, raw, i, report)
        end

        reload_hot unless report[:created].empty? && report[:updated].empty?
        emit(report)
        report
      end

      private

      def import_one(manifest, raw, index, report)
        defn = manifest.definition_for(raw, secrets: @secrets, env: @env)
        name = defn["name"].to_s
        raise Insika::ValidationError, "'#{name}' is already a code tool" if @registry.code_tool?(name)

        existed = !@tool_store.get(name).nil?
        @tool_store.write(defn)
        (existed ? report[:updated] : report[:created]) << name
      rescue Insika::Error => e
        report[:errors] << { tool: tool_label(raw, index), error: e.message }
      end

      def reload_hot
        @registry.reload
        @tool_catalog.reload
      end

      # Tool name for the error report; falls back to the index when the envelope
      # didn't even carry a name (keeps the error entry from being anonymous).
      def tool_label(raw, index)
        h = raw.is_a?(Hash) ? raw : {}
        name = h["name"] || h[:name] || h.dig("function", "name") || h.dig(:function, :name)
        Insika::Coercion.presence(name) || "#<tool ##{index}>"
      end

      # Emits only COUNTS + names (never headers/secrets): 0 leakage.
      def emit(report)
        @event_stream.emit(Insika::Event.new(
                             type: :tools_imported,
                             data: { created: report[:created].size, updated: report[:updated].size,
                                     errors: report[:errors].size },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
