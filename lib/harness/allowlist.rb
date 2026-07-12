# frozen_string_literal: true

module Harness
  # Semântica de allowlist do perfil, definida uma vez: nil = todos; [] = nenhum;
  # [names] = subconjunto. Aparecia copiada no Builder, no SkillCatalog e nas
  # policies — a regra tem que morar num lugar só.
  module Allowlist
    module_function

    # Filtra uma coleção pela allowlist, comparando `key.call(candidate)` (ou o
    # próprio candidato) contra os nomes permitidos.
    def filter(candidates, allow, &key)
      return candidates if allow.nil?
      return [] if allow.empty?

      names = Array(allow).map(&:to_s)
      candidates.select { |c| names.include?((key ? key.call(c) : c).to_s) }
    end

    # Variante booleana por item (para compor com outros filtros num select).
    def allows?(allow, value)
      return true if allow.nil?
      return false if allow.empty?

      Array(allow).map(&:to_s).include?(value.to_s)
    end
  end
end
