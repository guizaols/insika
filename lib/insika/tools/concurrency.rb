# frozen_string_literal: true

require "async"
require "async/semaphore"

module Insika
  module Tools
    # Fan-out INSIDE a single tool (§): when a tool must gather N
    # independent I/O calls (stock + price + promo + delivery) into ONE result,
    # `gather` runs them CONCURRENTLY on the turn's reactor and returns their values
    # IN ORDER. Because a data-tool spends its time on the HTTP wait, those waits
    # overlap → wall-clock ≈ the slowest call, not the sum.
    #
    # This is the "aggregator tool" pattern: the model makes ONE tool call and the
    # concurrency is an implementation detail of that tool — no change to the agent
    # loop, no dependency on parallel tool execution. Use it in a custom
    # Ruby tool's #execute:
    #
    #   def execute(store_id:)
    #     stock, price, promo = Insika::Tools::Concurrency.gather(
    #       -> { fetch_stock(store_id) },
    #       -> { fetch_price(store_id) },
    #       -> { fetch_promo(store_id) }
    #     )
    #     { stock:, price:, promo: }
    #   end
    #
    # Bounded by `max` concurrent (default 8) to respect upstream rate limits. Runs
    # correctly whether or not there is already a reactor (a tool runs inside the
    # turn's Async fiber; `Sync` reuses it, and starts one otherwise for tests).
    module Concurrency
      DEFAULT_MAX = 8

      module_function

      # blocks: callables (procs/lambdas) or a block yielding an index. Returns an
      # Array of results aligned to the input order. An exception in any block
      # propagates (the caller decides how to degrade — this helper does not swallow).
      def gather(*blocks, max: DEFAULT_MAX)
        blocks = blocks.flatten
        return [] if blocks.empty?

        results = Array.new(blocks.size)
        Sync do
          semaphore = Async::Semaphore.new([max, blocks.size].min)
          blocks.each_with_index.map do |blk, i|
            semaphore.async { results[i] = blk.call }
          end.each(&:wait)
        end
        results
      end
    end
  end
end
