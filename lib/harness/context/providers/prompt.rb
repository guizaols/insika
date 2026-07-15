# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Absorve SystemPrompt + SOUL.md. Identidade é
      # PINNED, priority 100 — nunca cortada. required?: agente sem identidade é
      # um agente ERRADO, não degradado. prompt_refs: fragmentos
      # priority 90 pinned, do PromptCatalog (catalog default nil).
      #
      # Identidade POR-AGENTE. `profile.prompt_files` (nomes de
      # arquivo) vence sobre os `files:` do wiring — resolve a limitação de um
      # agente novo herdar o prompt da Bia. O conteúdo vem do `agent_files`
      # (AgentFileStore, vive no Store), com fallback a File.read
      # para caminhos em disco (compat/seed). Sem prompt_files -> usa os `files:`
      # do wiring (default de deployment; paridade byte-a-byte).
      class Prompt < ContextProvider
        def initialize(base: "", files: [], catalog: nil, agent_files: nil, system_files: nil)
          @base = base
          @files = Array(files)
          @catalog = catalog
          @agent_files = agent_files
          @system_files = system_files
        end

        def required? = true

        def call(request)
          fragments = []
          identity = build_identity(request.profile)
          unless identity.empty?
            fragments << ContextFragment.build(content: identity, placement: :system,
                                               priority: Context::Priority::IDENTITY, source: id, pinned: true)
          end
          fragments.concat(ref_fragments(request.profile))
          fragments
        end

        private

        # Migra INTACTA a concatenação do SystemPrompt#build (sem skills_block).
        # Um fragmento ÚNICO preserva a ordem interna base->files (a ordenação
        # atua só ENTRE fragmentos) e garante a paridade byte-a-byte.
        #
        # profile.prompt_files (nomes) vence sobre @files (wiring): o agente com
        # identidade própria não herda a do deployment. Cada fonte resolve via
        # AgentFileStore (por agente) OU File.read (caminho em disco) — nesta
        # ordem. Sem prompt_files, cai nos @files do wiring.
        def build_identity(profile)
          parts = [@base]
          parts.concat(system_parts) # arquivos de sistema globais, para TODO agente
          sources = Array(profile&.prompt_files)
          if sources.empty?
            @files.each { |f| parts << File.read(f, encoding: "UTF-8") if File.exist?(f) }
          else
            sources.each { |src| parts << read_source(profile&.id, src.to_s) }
          end
          parts.reject { |p| p.nil? || p.strip.empty? }.join("\n\n")
        end

        # Arquivos de sistema GLOBAIS: valem para todos os agentes,
        # injetados ANTES da identidade individual. Store vazio/ausente -> [] ->
        # prompt byte-a-byte idêntico ao de antes (a injeção só existe se o
        # operador autorou algo). Ordem lexicográfica (SystemFileStore#list).
        def system_parts
          return [] unless @system_files

          @system_files.list.map { |name| @system_files.read(name).to_s }
        end

        # Store por-agente primeiro, disco depois (compat/seed).
        def read_source(agent_id, src)
          stored = agent_id && @agent_files&.read(agent_id, src)
          return stored if stored
          return File.read(src, encoding: "UTF-8") if File.exist?(src)

          ""
        end

        def ref_fragments(profile)
          refs = Array(profile.prompt_refs)
          return [] if refs.empty?

          refs.map do |name|
            entry = @catalog&.find(name.to_s)
            unless entry
              raise ContextError.new("prompt_ref '#{name}' não encontrado no Prompt Catalog",
                                     provider: id)
            end

            ContextFragment.build(content: entry.body, placement: :system,
                                  priority: Context::Priority::PROMPT_REF, source: id, pinned: true)
          end
        end
      end
    end
  end
end
