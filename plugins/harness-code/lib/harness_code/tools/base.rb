# frozen_string_literal: true

require "ruby_llm"
require_relative "../workspace"

module HarnessCode
  module Tools
    # Shared base for the code toolset. One instance per turn (the plugin
    # registers block factories that inject a shared, stateless Workspace).
    #
    # Mirrors the builtin tools (Harness::Tools::Remember/LoadSkill): subclass of
    # RubyLLM::Tool, an explicit `#name` override (RubyLLM derives a mangled name
    # from a namespaced class), and `#execute(**kwargs)`. `#guard` funnels sandbox
    # escapes and IO errors into a `{ error: ... }` hash returned to the MODEL, so
    # a bad path is a recoverable tool result — never a crashed turn.
    class Base < RubyLLM::Tool
      def initialize(workspace:)
        @workspace = workspace
        super()
      end

      private

      attr_reader :workspace

      def guard
        yield
      rescue Workspace::Escape => e
        { error: "sandbox: #{e.message}" }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end
    end
  end
end
