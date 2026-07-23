# frozen_string_literal: true

module Insika
  # Per-gem boot hook (Railtie style): the plugin gem
  # calls Insika::Plugin.announce(root) when loading its lib/ (before boot); the
  # composition root consumes announced_roots when building the Loader. Explicit
  # and cheap — NO scanning of LOAD_PATH/installed gems.
  #
  # This file is MINIMAL and dependency-free: third-party gems can load it
  # before anything else from Insika. The Loader lives in plugin/loader.rb
  # (same module, reopened) — this file does NOT require it.
  module Plugin
    @announced_roots = []

    class << self
      # Accumulates roots BEFORE boot, in the gems' require ORDER (that's what
      # defines precedence among gems). Dedupes by expanded path.
      def announce(root)
        root = File.expand_path(root.to_s)
        @announced_roots << root unless @announced_roots.include?(root)
        root
      end

      # Frozen copy — nobody mutates the accumulator from outside.
      def announced_roots
        @announced_roots.dup.freeze
      end

      # TEST support (the accumulator is process state). Do not use in production.
      def reset_announced!
        @announced_roots = []
      end
    end
  end
end
