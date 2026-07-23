# frozen_string_literal: true

require "delegate"

module Insika
  module Capability
    # Thin decorator: swaps only the `name` exposed to the model for the
    # STABLE capability name (e.g. "browse"), regardless of which concrete impl
    # (`impl_name`, e.g. "puppeteer_browser") resolution chose.
    # `execute`/`parameters`/`description`/`call` keep delegating to the impl via
    # SimpleDelegator — nothing reimplemented, same spirit as `ToolEnvelope`.
    #
    # Wrapping order in run_pipeline: impl -> ResolvedTool ->
    # ToolEnvelope. The Envelope, from the outside, sees the already-renamed call (the
    # model calls `browse`); for side_effect?/approval it needs the REAL `impl_name`
    # (it's the tool_registry that knows whether "puppeteer_browser" is a side-effect, not
    # "browse") — that's why `impl_name` is exposed here. This is consumed by the
    # Executor (ToolEnvelope).
    class ResolvedTool < SimpleDelegator
      def initialize(impl, capability_name:, impl_name:)
        super(impl)
        @capability_name = capability_name.to_s
        @impl_name = impl_name.to_s
      end

      # STABLE name exposed to the model — shadows the impl's `name`.
      def name = @capability_name

      # Concrete name behind resolution — for side_effect?/approval in the
      # ToolEnvelope, NEVER exposed to the model.
      def impl_name = @impl_name
    end
  end
end
