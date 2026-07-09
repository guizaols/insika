# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Absorve SystemPrompt + SOUL.md (Fase 0, doc 04 §2/§8). Identidade é
      # PINNED, priority 100 — nunca cortada. required?: agente sem identidade é
      # um agente ERRADO, não degradado (doc 04 §6). prompt_refs (D6): fragmentos
      # priority 90 pinned, do PromptCatalog (task 20; catalog default nil).
      class Prompt < ContextProvider
        def initialize(base: "", files: [], catalog: nil)
          @base = base
          @files = Array(files)
          @catalog = catalog
        end

        def required? = true

        def call(request)
          fragments = []
          identity = build_identity
          unless identity.empty?
            fragments << ContextFragment.build(content: identity, placement: :system,
                                               priority: 100, source: id, pinned: true)
          end
          fragments.concat(ref_fragments(request.profile))
          fragments
        end

        private

        # Migra INTACTA a concatenação do SystemPrompt#build (sem skills_block).
        # Um fragmento ÚNICO preserva a ordem interna base->files (a task 14
        # ordena só ENTRE fragmentos) e garante a paridade byte-a-byte.
        def build_identity
          parts = [@base]
          @files.each { |f| parts << File.read(f, encoding: "UTF-8") if File.exist?(f) }
          parts.reject { |p| p.nil? || p.strip.empty? }.join("\n\n")
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
                                  priority: 90, source: id, pinned: true)
          end
        end
      end
    end
  end
end
