# frozen_string_literal: true

require "fileutils"

module HarnessCode
  # HARD security boundary of the code toolset: confines every filesystem/shell
  # operation to a single root directory. Each model/user supplied path is
  # resolved and verified to live INSIDE the root BEFORE any IO happens. This is
  # enforced by the tools themselves (always on), independent of — and in
  # addition to — the engine's approval layer.
  #
  # Two layers of defense implemented here:
  #   1. `File.expand_path` normalizes `..` traversal; the expanded path must be
  #      the root itself or a descendant of it (string containment on a
  #      separator boundary, so `/ws-evil` does not pass for root `/ws`).
  #   2. symlink guard: for an existing target (or, on writes, its parent dir)
  #      the REAL path (`File.realpath`, which follows symlinks) must also be
  #      contained — a symlink inside the workspace pointing outside is rejected.
  #
  # The boundary is a value object: immutable root, no IO of its own beyond the
  # realpath checks. Tools do the actual reads/writes on the vetted absolute
  # path returned by `#resolve`.
  class Workspace
    # Raised on any attempt to touch a path outside the workspace root. Tools
    # rescue it and return a structured error to the model (never crash a turn).
    Escape = Class.new(StandardError)

    attr_reader :root

    # root: the directory that bounds all operations. Must exist (a workspace
    # rooted at a missing dir is a misconfiguration -> fail fast at boot).
    def initialize(root)
      @root = File.realpath(File.expand_path(root.to_s))
    rescue Errno::ENOENT
      raise Escape, "workspace root does not exist: #{root}"
    end

    # Resolve a relative/absolute path to an absolute path GUARANTEED inside the
    # root. Raises Escape on traversal/symlink escape or an empty path.
    #   for_write: the target file may not exist yet, so the symlink guard is
    #   applied to its PARENT directory instead of the file itself.
    def resolve(path, for_write: false)
      raise Escape, "empty path" if path.to_s.strip.empty?

      abs = File.expand_path(path.to_s, @root)
      contain!(abs)

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

      raise Escape, "path escapes workspace root (#{relative_or_abs(abs)})"
    end

    def relative_or_abs(abs) = abs.start_with?(@root) ? relative(abs) : abs
  end
end
