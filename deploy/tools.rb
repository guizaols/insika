# frozen_string_literal: true

require "ruby_llm"
require "time"

# Tools REAIS do deployment de demo (padrão OpenClaw). Retornam dados de verdade
# (não mocks): o modelo decide chamá-las e recebe o retorno concreto.
module Deploy
  module Tools
    class Menu < RubyLLM::Tool
      description "Retorna o cardápio da Pizzaria do Zé (itens e preços em BRL)."
      def name = "menu"

      ITEMS = {
        "Pizza Margherita" => 45.0, "Pizza Calabresa" => 49.0,
        "Pizza Portuguesa" => 52.0, "Salada Caesar" => 28.0,
        "Suco Natural 500ml" => 12.0, "Refrigerante Lata" => 7.0
      }.freeze

      def execute = { currency: "BRL", items: ITEMS }
    end

    class Calc < RubyLLM::Tool
      description "Avalia uma expressão aritmética simples (ex.: '45 + 49 + 12'). Só números e + - * / ( )."
      param :expression, desc: "A expressão a calcular, ex.: '45 + 45'"
      def name = "calc"

      def execute(expression:)
        expr = expression.to_s
        return { error: "expressão inválida (só números e + - * / . ( ))" } unless expr.match?(%r{\A[\d\s+\-*/().]+\z})

        { expression: expr, result: eval(expr) } # rubocop:disable Security/Eval — entrada já validada por regex
      rescue StandardError => e
        { error: "não consegui calcular: #{e.class}" }
      end
    end

    class CurrentTime < RubyLLM::Tool
      description "Retorna a data e hora atuais (America/Sao_Paulo)."
      def name = "current_time"

      def execute
        t = Time.now.getlocal("-03:00")
        { iso: t.iso8601, weekday: %w[domingo segunda terça quarta quinta sexta sábado][t.wday],
          time: t.strftime("%H:%M") }
      end
    end

    ALL = { "menu" => Menu, "calc" => Calc, "current_time" => CurrentTime }.freeze
  end
end
