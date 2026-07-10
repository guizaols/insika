# frozen_string_literal: true

module Harness
  # Base executável genérica (RFC-0001 princípio 6, doc 06 §2): Registry =
  # conteúdo EXECUTÁVEL (tools/workflows/policies). Catalog (skills/prompts) é
  # não-executável e não herda daqui.
  #
  # Imutável pós-boot por CONSTRUÇÃO (só o boot registra — doc 06 §5, L6): não
  # há `freeze!`; a imutabilidade não é imposta em runtime.
  class Registry
    Entry = Data.define(:name, :plugin, :metadata, :factory)

    def initialize
      @entries = {}
    end

    # factory = bloco OU o callable posicional. metadata capturado por **kw
    # (chaves Symbol, guardado como veio). Duplicata: PRIMEIRO vence (precedência
    # de plugin, RFC-0003 §5) — o segundo é descartado com warn, nunca overwrite.
    def register(name, callable = nil, plugin: nil, **metadata, &block)
      name = name.to_s
      factory = block || (callable.nil? ? nil : -> { callable })
      raise ArgumentError, "registro sem factory: #{name}" if factory.nil?

      if @entries.key?(name)
        existing = @entries[name]
        warn "[registry] '#{name}' já registrada por #{existing.plugin.inspect}; " \
             "descartando registro de #{plugin.inspect} (primeiro vence)"
        return self
      end

      @entries[name] = Entry.new(name: name, plugin: plugin&.to_s, metadata: metadata, factory: factory)
      self
    end

    # -> instância (factory.call) | raise NotFoundError (D4).
    def resolve(name)
      entry = @entries[name.to_s]
      raise Harness::NotFoundError, "'#{name}' não registrada em #{self.class}" if entry.nil?

      entry.factory.call
    end

    def entries = @entries.values
    def names = @entries.keys

    # Suporte a rollback do Loader (doc 06 §6, L3): remove as entries de um
    # plugin. NÃO é API de runtime (registries são imutáveis pós-boot).
    def deregister_plugin(plugin_id)
      @entries.delete_if { |_name, entry| entry.plugin == plugin_id.to_s }
      nil
    end
  end
end
