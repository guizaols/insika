# frozen_string_literal: true

require "zlib"

module Insika
  module Router
    # Ketama-style consistent hash ring. Each backend gets
    # `replicas` virtual points on a 0..2**32-1 circle (CRC32 of "backend#i");
    # a key's owner is the first point clockwise from CRC32(key). Removing or
    # adding one backend only remaps the ~1/N of the space that belonged to
    # that backend's own points — not the whole ring — which is what keeps a
    # rolling deploy from bouncing every live session to a new owner at once.
    class HashRing
      DEFAULT_REPLICAS = 160

      def initialize(backends, replicas: DEFAULT_REPLICAS)
        raise ArgumentError, "at least one backend is required" if Array(backends).empty?

        @replicas = replicas
        @backends = backends.uniq.sort
        @ring = {}
        @backends.each do |backend|
          @replicas.times { |i| @ring[Zlib.crc32("#{backend}\0#{i}")] = backend }
        end
        @points = @ring.keys.sort
      end

      attr_reader :backends, :points, :ring

      # -> the backend owning `key` — the first ring point at or after
      # CRC32(key), wrapping around to the first point when `key` hashes past
      # the last one. O(log N) via binary search, not a hash-map rebuild.
      def backend_for(key)
        backend_for_point(Zlib.crc32(key.to_s))
      end

      # Fraction of a representative KEY SAMPLE whose owner changes between
      # two rings — the measurement acceptance §6.2 asks for, not an
      # assumption. (Ring POINTS themselves are the wrong yardstick: a's/b's/
      # c's/d's own points stay put when "e" is added — only the space of
      # arbitrary keys BETWEEN points shifts.) `sample_size` large enough that
      # the law of large numbers keeps the estimate tight without a spec
      # needing thousands of literal keys of its own.
      def self.remapped_fraction(before, after, sample_size: 20_000)
        moved = (0...sample_size).count { |i| before.backend_for(i) != after.backend_for(i) }
        moved.to_f / sample_size
      end

      def backend_for_point(point)
        idx = @points.bsearch_index { |p| p >= point } || 0
        @ring[@points[idx]]
      end
    end
  end
end
