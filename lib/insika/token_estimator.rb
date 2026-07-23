# frozen_string_literal: true

module Insika
  # Cheap token estimate behind an interface.
  # Default: text.length / 4 (off by ~±15%, absorbed by the budget margin).
  # Swappable for a real tokenizer without touching the Builder: any object that
  # responds to #estimate(text) -> Integer works as a replacement (injected at the
  # composition root).
  module TokenEstimator
    module_function

    def estimate(text)
      text.to_s.length.ceildiv(4)
    end
  end
end
