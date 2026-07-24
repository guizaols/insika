# frozen_string_literal: true

module Insika
  # Definition-time integrity of the subagent delegation graph (RFC-0010 §4.4,
  # item 21). A pure function over `{id => [child_ids]}`: detects CYCLES and
  # computes the max delegation DEPTH, raising a typed SubagentError so the
  # authoring Command (CreateAgent/UpdateAgent) fails cleanly and boot refuses a
  # bad static set. Cycle + bounded depth are exactly Flue's definition-time
  # guarantee (`DelegationDepthExceededError` + anti-circular) — with the graph
  # acyclic and depth <= cap, the runtime is provably bounded (the guard in
  # Executor#run_subagent is only belt-and-suspenders for a graph that changed
  # mid-run).
  #
  # UNKNOWN child refs are treated as LEAVES (no outgoing edges), NOT an error:
  # dynamic authoring must not break by creation order — a not-yet-created child
  # surfaces as a clean "not found" at runtime (run_subagent), not a boot failure.
  module SubagentGraph
    # Longest delegation chain allowed (root counts as depth 0; each spawn +1).
    # Override with INSIKA_SUBAGENT_DEPTH_CAP.
    DEFAULT_DEPTH_CAP = 5

    # Max children a single `spawn_subagents` fan-out may run — also the concurrency
    # bound (N concurrent LLM calls hit the provider rate limit + the per-agent token
    # ceiling of item 33). Override with INSIKA_SUBAGENT_FANOUT_CAP.
    DEFAULT_FANOUT_CAP = 8

    module_function

    def depth_cap
      int_env("INSIKA_SUBAGENT_DEPTH_CAP", DEFAULT_DEPTH_CAP)
    end

    def fan_out_cap
      int_env("INSIKA_SUBAGENT_FANOUT_CAP", DEFAULT_FANOUT_CAP)
    end

    def int_env(name, default)
      raw = Insika::EnvSchema.read(name)
      raw && !raw.strip.empty? ? Integer(raw) : default
    end

    # Validates the whole set. `profiles` is anything enumerable of profiles
    # responding to #id and #subagents (an Array or a ProfileSource#all result),
    # OR a plain `{id => [child_ids]}` Hash. Raises on the FIRST violation.
    def validate!(profiles, cap: depth_cap)
      map = to_map(profiles)
      map.each_key { |root| check_from(root, map, cap) }
      map
    end

    # Builds the {id => [child_ids]} adjacency map. Absent/nil subagents => [].
    def to_map(profiles)
      return normalize(profiles) if profiles.is_a?(Hash)

      each_profile(profiles).each_with_object({}) do |p, acc|
        acc[p.id.to_s] = Array(p.subagents).map(&:to_s)
      end
    end

    # DFS from `root` tracking the recursion stack (cycle) and the longest path
    # (depth). A ref to an id absent from `map` is a leaf.
    def check_from(root, map, cap)
      walk(root, map, cap, [], {})
    end

    # Returns the max depth of the subtree rooted at `node`. `stack` is the
    # current path (cycle detection); `memo` caches finished subtrees.
    def walk(node, map, cap, stack, memo)
      raise SubagentCycleError.new(cycle: stack + [node]) if stack.include?(node)
      return memo[node] if memo.key?(node)

      children = map[node] || [] # unknown ref => leaf
      depth = if children.empty?
                0
              else
                1 + children.map { |c| walk(c, map, cap, stack + [node], memo) }.max
              end
      raise SubagentDepthExceeded.new(depth: depth, cap: cap) if depth > cap

      memo[node] = depth
    end

    def normalize(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = Array(v).map(&:to_s) }
    end

    # Duck-typed enumeration: an Array of profiles, or a ProfileSource exposing
    # #all. Anything else Enumerable is iterated as-is.
    def each_profile(profiles)
      return profiles if profiles.is_a?(Array)
      return profiles.all if profiles.respond_to?(:all)

      Array(profiles)
    end
  end
end
