# frozen_string_literal: true

require_relative "base"

module InsikaCode
  module Tools
    # List the entries of a directory in the workspace (one level, not
    # recursive). Read-only.
    class ListDir < Base
      description "Lists the entries (files and sub-directories) of a directory in the sandbox."
      param :path, desc: "Directory path relative to the workspace root (default: the root)",
                   required: false

      def name = "list_dir"

      def execute(path: ".")
        guard do
          rel = path.to_s.strip.empty? ? "." : path
          abs = sandbox.resolve(rel)
          raise "not a directory: #{rel}" unless File.directory?(abs)

          entries = Dir.children(abs).sort.map do |name|
            full = File.join(abs, name)
            { name: name, type: File.directory?(full) ? "dir" : "file" }
          end
          { path: sandbox.relative(abs), entries: entries }
        end
      end
    end
  end
end
