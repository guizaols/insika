# frozen_string_literal: true

require "fileutils"

module Insika
  module Sandbox
    # HARD filesystem boundary: confines every path a tool resolves to a single
    # root directory. Each model/user supplied path is resolved and verified to
    # live INSIDE the root BEFORE any IO happens. This is the FS half of the
    # sandbox primitive — always on, independent of the exec provider (local or
    # docker) and of the engine's approval layer.
    #
    # Extracted VERBATIM from the insika-code prototype's `Workspace` (item 5)
    # and promoted to a core primitive (item 35). The two layers of defense:
    #   1. `File.expand_path` normalizes `..` traversal; the expanded path must be
    #      the root itself or a descendant of it (string containment on a
    #      separator boundary, so `/ws-evil` does not pass for root `/ws`).
    #   2. symlink guard: the final path component may never be a symlink (an
    #      lstat check that also catches a BROKEN symlink whose target does not
    #      yet exist), and for an existing target (or, on writes, its parent dir)
    #      the REAL path (`File.realpath`, which follows symlinks) must also be
    #      contained — a symlink inside the sandbox pointing outside is rejected.
    #
    # A value object: immutable root, no IO of its own beyond the realpath checks.
    class Boundary
      # Raised on any attempt to touch a path outside the root. Tools rescue it
      # and return a structured error to the model (never crash a turn).
      Escape = Class.new(StandardError)

      attr_reader :root

      # root: the directory that bounds all operations. Must exist (a boundary
      # rooted at a missing dir is a misconfiguration -> fail fast at boot).
      def initialize(root)
        @root = File.realpath(File.expand_path(root.to_s))
      rescue Errno::ENOENT
        raise Escape, "sandbox root does not exist: #{root}"
      end

      # Resolve a relative/absolute path to an absolute path GUARANTEED inside the
      # root. Raises Escape on traversal/symlink escape or an empty path.
      #   for_write: the target file may not exist yet, so the symlink guard is
      #   applied to its PARENT directory instead of the file itself.
      def resolve(path, for_write: false)
        raise Escape, "empty path" if path.to_s.strip.empty?

        abs = File.expand_path(path.to_s, @root)
        contain!(abs)

        # The final component is never allowed to be a symlink. On writes this is
        # the crux of the boundary: `contain!` only checks the STRING, and the
        # parent-dir realpath probe below only vets the parent — so without this a
        # symlink under the root pointing outside would let `File.write` follow it
        # and clobber a file outside the sandbox. `File.symlink?` is an lstat, so
        # it also catches a BROKEN symlink (dangling target) that `File.exist?`
        # would report as absent.
        raise Escape, "path is a symlink" if File.symlink?(abs)

        probe = for_write ? File.dirname(abs) : abs
        contain!(File.realpath(probe)) if File.exist?(probe)
        abs
      end

      # Boolean containment check for an ALREADY-absolute path (used by grep to
      # skip glob results that resolve outside the root via a symlink). Never
      # raises.
      def inside?(abs)
        real = File.exist?(abs) ? File.realpath(abs) : File.expand_path(abs)
        real == @root || real.start_with?(@root + File::SEPARATOR)
      rescue StandardError
        false
      end

      # Path relative to the root, for display — never leaks absolute host paths
      # back to the model. The root itself renders as ".".
      def relative(abs)
        return "." if abs == @root

        abs.delete_prefix(@root + File::SEPARATOR)
      end

      private

      def contain!(abs)
        return if abs == @root || abs.start_with?(@root + File::SEPARATOR)

        raise Escape, "path escapes sandbox root (#{relative_or_abs(abs)})"
      end

      def relative_or_abs(abs) = abs.start_with?(@root) ? relative(abs) : abs
    end
  end
end
