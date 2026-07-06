# frozen_string_literal: true

module Harness
  # Estimativa de tokens barata atrás de interface (00-overview D8).
  # Default: text.length / 4 (erra ~±15%, absorvido pela margem do budget).
  # Trocável por tokenizer real sem tocar no Builder: qualquer objeto que
  # responda a #estimate(text) -> Integer serve como substituto (injeção no
  # composition root, doc 04).
  module TokenEstimator
    module_function

    def estimate(text)
      (text.to_s.length / 4.0).ceil
    end
  end
end
