# frozen_string_literal: true

module Harness
  # Unit of context produced by a provider.
  # SHARED type (Harness::, not Harness::Context::).
  #   placement: :system | :history | :tool_context
  #   priority:  Integer; higher = more important (survives cuts)
  #   tokens:    Integer | nil; estimated by the Builder when nil
  #   source:    String — provider id (audit)
  #   pinned:    true -> uncuttable in the budget (e.g. identity)
  ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                                :source, :pinned) do
    def self.build(content:, placement:, source:, priority: 50, tokens: nil,
                   pinned: false)
      new(content: content, placement: placement, priority: priority,
          tokens: tokens, source: source, pinned: pinned)
    end
  end
end
