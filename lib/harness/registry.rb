# frozen_string_literal: true

module Harness
  # Generic executable base: Registry =
  # EXECUTABLE content (tools/workflows/policies). Catalog (skills/prompts) is
  # non-executable and does not inherit from here.
  #
  # Immutable post-boot by CONSTRUCTION (only boot registers): there
  # is no `freeze!`; immutability is not enforced at runtime.
  class Registry
    Entry = Data.define(:name, :plugin, :metadata, :factory)

    def initialize
      @entries = {}
    end

    # factory = block OR the positional callable. metadata captured by **kw
    # (Symbol keys, stored as-is). Duplicate: FIRST wins (plugin precedence)
    # — the second is discarded with a warn, never overwritten.
    def register(name, callable = nil, plugin: nil, **metadata, &block)
      name = name.to_s
      factory = block || (callable.nil? ? nil : -> { callable })
      raise ArgumentError, "registration without factory: #{name}" if factory.nil?

      if @entries.key?(name)
        existing = @entries[name]
        warn "[registry] '#{name}' already registered by #{existing.plugin.inspect}; " \
             "descartando registro de #{plugin.inspect} (primeiro vence)"
        return self
      end

      @entries[name] = Entry.new(name: name, plugin: plugin&.to_s, metadata: metadata, factory: factory)
      self
    end

    # -> instance (factory.call) | raise NotFoundError.
    def resolve(name)
      entry(name).factory.call
    end

    # -> the raw Entry (name/plugin/metadata/factory) | raise NotFoundError. For
    # readers that need the metadata WITHOUT resolving the factory (discovery,
    # WorkflowRegistry#definition).
    def entry(name)
      @entries[name.to_s] ||
        (raise Harness::NotFoundError, "'#{name}' not registered in #{self.class}")
    end

    def entries = @entries.values
    def names = @entries.keys

    # Loader rollback support: removes the entries of a
    # plugin. NOT a runtime API (registries are immutable post-boot).
    def deregister_plugin(plugin_id)
      @entries.delete_if { |_name, entry| entry.plugin == plugin_id.to_s }
      nil
    end
  end
end
