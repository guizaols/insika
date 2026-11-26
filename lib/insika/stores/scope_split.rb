# frozen_string_literal: true

module Insika
  module Stores
    # Two backends seen as one: the scopes that start with `prefix` live in `side`,
    # everything else in `main`.
    #
    # Why: at boot every worker reloads the config (prompts, skills, tools, ~60 MB).
    # Inside the big database those rows sit scattered among GBs of conversations,
    # and a fresh container reads them at random from a cold disk: 7-20s with all
    # workers stalled after each deploy. In their own small file the whole config
    # is one sequential read of about a second (deploy/entrypoint.sh warms it).
    #
    # A transaction opens on both, so a block may touch either side. It is not
    # atomic ACROSS the two files; no caller writes config and conversation data in
    # one transaction (ConfigStore's write + version bump are both config).
    class ScopeSplit
      include Store

      attr_reader :main, :side

      def initialize(main:, side:, prefix: "config:")
        @main = main
        @side = side
        @prefix = prefix
      end

      # One-time move on a deployment that turns the split on: copies the prefix's
      # rows from main into an empty side. They stay in main (a rollback still finds
      # them); later writes go to side only. -> number of rows copied.
      def adopt!
        return 0 unless @side.scopes(@prefix).empty?

        copied = 0
        @side.transaction do
          @main.scopes(@prefix).each do |scope|
            @main.entries(scope).each do |key, value|
              @side.set(scope, key, value)
              copied += 1
            end
          end
        end
        copied
      end

      def get(scope, key) = route(scope).get(scope, key)
      def set(scope, key, value) = route(scope).set(scope, key, value)
      def amend(scope, key, value) = route(scope).amend(scope, key, value)
      def delete(scope, key) = route(scope).delete(scope, key)
      def list(scope, prefix = nil) = route(scope).list(scope, prefix)
      def entries(scope, prefix = nil) = route(scope).entries(scope, prefix)
      def recent(scope, prefix, limit, offset = 0) = route(scope).recent(scope, prefix, limit, offset)

      def scopes(prefix = nil)
        return @side.scopes(prefix) if prefix.to_s.start_with?(@prefix)

        (@main.scopes(prefix).reject { |s| side?(s) } + @side.scopes(prefix).select { |s| side?(s) }).sort
      end

      def transaction(&blk) = @main.transaction { @side.transaction(&blk) }

      def close
        @main.close if @main.respond_to?(:close)
        @side.close if @side.respond_to?(:close)
      end

      private

      def side?(scope) = scope.to_s.start_with?(@prefix)
      def route(scope) = side?(scope) ? @side : @main
    end
  end
end
