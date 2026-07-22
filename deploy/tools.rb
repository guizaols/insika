# frozen_string_literal: true

require "ruby_llm"
require "time"

# REAL tools for the demo deployment (OpenClaw style). They return actual data
# (not mocks): the model decides to call them and receives the concrete result.
module Deploy
  module Tools
    class Menu < RubyLLM::Tool
      description "Returns Joe's Pizzeria menu (items and prices in BRL)."
      def name = "menu"

      ITEMS = {
        "Margherita Pizza" => 45.0, "Pepperoni Pizza" => 49.0,
        "Four Cheese Pizza" => 52.0, "Caesar Salad" => 28.0,
        "Fresh Juice 500ml" => 12.0, "Canned Soda" => 7.0
      }.freeze

      def execute = { currency: "BRL", items: ITEMS }
    end

    class Calc < RubyLLM::Tool
      description "Evaluates a simple arithmetic expression (e.g. '45 + 49 + 12'). Only digits and + - * / ( )."
      param :expression, desc: "The expression to compute, e.g. '45 + 45'"
      def name = "calc"

      def execute(expression:)
        expr = expression.to_s
        return { error: "invalid expression (only digits and + - * / . ( ))" } unless expr.match?(%r{\A[\d\s+\-*/().]+\z})

        { expression: expr, result: eval(expr) } # rubocop:disable Security/Eval — input already validated by regex
      rescue StandardError => e
        { error: "could not compute: #{e.class}" }
      end
    end

    class CurrentTime < RubyLLM::Tool
      description "Returns the current date and time (America/Sao_Paulo)."
      def name = "current_time"

      def execute
        t = Time.now.getlocal("-03:00")
        { iso: t.iso8601, weekday: %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday][t.wday],
          time: t.strftime("%H:%M") }
      end
    end

    ALL = { "menu" => Menu, "calc" => Calc, "current_time" => CurrentTime }.freeze
  end
end
