# frozen_string_literal: true

require "ruby_llm"

# Insika::Sandbox is always loaded before any plugin (the Plugin::Loader is part
# of the engine), so the constant resolves at call time without a require here —
# same convention as the other plugin tools (they never require the core).
module InsikaCode
  module Tools
    # Shared base for the code toolset. One instance per turn (the plugin
    # registers block factories that inject a shared, stateless Sandbox).
    #
    # Mirrors the builtin tools (Insika::Tools::Remember/LoadSkill): subclass of
    # RubyLLM::Tool, an explicit `#name` override (RubyLLM derives a mangled name
    # from a namespaced class), and `#execute(**kwargs)`. `#guard` funnels sandbox
    # escapes and IO errors into a `{ error: ... }` hash returned to the MODEL, so
    # a bad path is a recoverable tool result — never a crashed turn.
    #
    # As of item 35 the injected object is the core `Insika::Sandbox::Env`
    # (FS boundary + exec provider), replacing the plugin-local Workspace.
    class Base < RubyLLM::Tool
      def initialize(sandbox:)
        @sandbox = sandbox
        super()
      end

      private

      attr_reader :sandbox

      def guard
        yield
      rescue Insika::Sandbox::Escape => e
        { error: "sandbox: #{e.message}" }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end
    end
  end
end
