# frozen_string_literal: true

require "yaml"

module Harness
  # Parser TOLERANTE de frontmatter (o bloco YAML `--- ... ---` de um SKILL.md).
  # A convenção é YAML, mas packs reais trazem PROSA no `description` — com `: `
  # (dois-pontos + espaço), aspas, parênteses — que o YAML ESTRITO rejeita
  # ("mapping values are not allowed in this context"). O gateway OpenClaw tolera;
  # o harness precisa tolerar também (NF2: o mesmo pack tem que valer).
  #
  # Estratégia: tenta YAML (respeita quoted / multi-line / listas); se o YAML
  # falhar OU não render um Hash, cai num parse LINHA-A-LINHA que separa no
  # PRIMEIRO `:` e trata o resto como string crua — recupera name/description
  # mesmo com `: ` no meio do valor. -> Hash de chaves String. NUNCA levanta.
  module Frontmatter
    module_function

    def parse(text)
      loaded = begin
        YAML.safe_load(text.to_s)
      rescue Psych::SyntaxError
        nil
      end
      loaded.is_a?(Hash) ? stringify(loaded) : lenient(text)
    end

    # Split no primeiro `:` de cada linha; valor = resto (string). Linha sem `:`
    # é ignorada. Preserva `: ` internos ao valor (o caso que quebra o YAML).
    def lenient(text)
      text.to_s.each_line.each_with_object({}) do |line, acc|
        next unless line.include?(":")

        key, _, value = line.partition(":")
        k = key.strip
        acc[k] = value.strip unless k.empty?
      end
    end

    def stringify(hash) = hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
  end
end
