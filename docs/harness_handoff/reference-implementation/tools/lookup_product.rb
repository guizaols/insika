# frozen_string_literal: true

require "ruby_llm"

# Tool de exemplo (in-process). Plugue seu catálogo real aqui.
# Nome exposto ao modelo: "lookup_product" (derivado do nome da classe).
class LookupProduct < RubyLLM::Tool
  description "Busca um produto no catálogo por nome ou termo"
  param :query, desc: "Nome ou termo de busca do produto"

  def execute(query:)
    # STUB — troque pela query real (Product.where(...) etc.)
    [
      { name: "#{query} (exemplo)", price: 199.90, sku: "SKU-#{query.upcase[0, 3]}" }
    ]
  end
end
