# frozen_string_literal: true

module Insika
  module Stores
    # Counts every store call into the running turn's TurnTiming, so a turn's
    # completion event says how many round trips it cost and to which scopes.
    # Prepended to one backend instance; with no turn running it only forwards.
    module TurnCounter
      OPS = %i[get set delete list scopes entries recent transaction].freeze

      OPS.each do |op|
        define_method(op) do |*args, &blk|
          Insika::TurnTiming.current&.count_store(op, args.first)
          super(*args, &blk)
        end
      end

      # -> the same backend, counting from now on (idempotent).
      def self.attach(backend)
        backend.singleton_class.prepend(self) unless backend.singleton_class.include?(self)
        backend
      end
    end
  end
end
