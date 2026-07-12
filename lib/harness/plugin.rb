# frozen_string_literal: true

module Harness
  # Boot hook por gem (estilo Railtie): a gem de plugin
  # chama Harness::Plugin.announce(root) no load do seu lib/ (antes do boot); o
  # composition root consome announced_roots ao montar o Loader. Explícito e
  # barato — NADA de scan de LOAD_PATH/gems instaladas.
  #
  # Este arquivo é MÍNIMO e sem dependências: gems de terceiros podem carregá-lo
  # antes de qualquer outra coisa do Harness. O Loader vive em plugin/loader.rb
  # (mesmo módulo, reaberto) — este arquivo NÃO o requer.
  module Plugin
    @announced_roots = []

    class << self
      # Acumula roots ANTES do boot, na ORDEM de require das gems (é ela que
      # define a precedência entre gems). Deduplica por path expandido.
      def announce(root)
        root = File.expand_path(root.to_s)
        @announced_roots << root unless @announced_roots.include?(root)
        root
      end

      # Cópia congelada — ninguém muta o acumulador por fora.
      def announced_roots
        @announced_roots.dup.freeze
      end

      # Suporte de TESTE (o acumulador é estado de processo). Não usar em produção.
      def reset_announced!
        @announced_roots = []
      end
    end
  end
end
