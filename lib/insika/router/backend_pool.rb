# frozen_string_literal: true

require "resolv"
require_relative "hash_ring"

module Insika
  module Router
    # Backend discovery + the ring it feeds (RFC-0043 §3.4). Two modes:
    #
    #   static — a fixed list, resolved once (the Railway shape: N local
    #     Falcon workers on known ports inside one container).
    #   dns    — one hostname re-resolved on an interval (the Kubernetes
    #     shape: a headless Service, one A/AAAA record per ready pod).
    #
    # The ring is rebuilt ONLY when the resolved set actually changed — a DNS
    # poll that returns the same pods is a no-op, not a ring rebuild every
    # `dns_interval` seconds.
    class BackendPool
      def initialize(static: nil, dns: nil, dns_port: nil, dns_interval: 15,
                      replicas: HashRing::DEFAULT_REPLICAS, resolver: Resolv, logger: $stdout)
        raise ArgumentError, "static or dns is required, not both" if static.nil? == dns.nil?
        raise ArgumentError, "dns_port is required with dns:" if dns && dns_port.nil?
        raise ArgumentError, "static must not be empty" if static && Array(static).empty?

        @static = Array(static)
        @dns = dns
        @dns_port = dns_port
        @dns_interval = dns_interval
        @replicas = replicas
        @resolver = resolver
        @logger = logger
        @mutex = Mutex.new
        @ring = nil
        refresh!
      end

      def dns? = !@dns.nil?

      def ring
        @mutex.synchronize { @ring }
      end

      def backends
        @mutex.synchronize { @ring&.backends || [] }
      end

      # Re-resolves (a no-op for static after the first call) and rebuilds
      # the ring iff the resolved set changed. -> bool (did it change?).
      def refresh!
        resolved = @dns ? resolve_dns : @static
        if resolved.empty?
          log("router: 0 backends resolved — keeping the previous ring" \
              "#{" (#{@ring.backends.size} backend(s))" if @ring}")
          return false
        end

        @mutex.synchronize do
          return false if @ring && @ring.backends.sort == resolved.sort

          @ring = HashRing.new(resolved, replicas: @replicas)
        end
        log("router: ring rebuilt — #{resolved.sort.join(', ')}")
        true
      end

      # Starts the periodic re-resolve loop (dns mode only — a no-op for
      # static) inside the caller's Async task, so a spec can drive #refresh!
      # directly without ever starting this loop.
      def start_polling(task)
        return unless dns?

        task.async do |t|
          loop do
            t.sleep(@dns_interval)
            refresh!
          rescue StandardError => e
            log("router: DNS re-resolve failed (#{e.class}: #{e.message}) — keeping the previous ring")
          end
        end
      end

      private

      def resolve_dns
        @resolver.getaddresses(@dns).map { |ip| "http://#{ip.include?(':') ? "[#{ip}]" : ip}:#{@dns_port}" }
      rescue StandardError => e
        log("router: DNS resolve of #{@dns} failed (#{e.class}: #{e.message})")
        []
      end

      def log(message)
        @logger&.puts(message)
      rescue StandardError
        nil
      end
    end
  end
end
