# frozen_string_literal: true

module Insika
  # Unit of context produced by a provider.
  # SHARED type (Insika::, not Insika::Context::).
  #   placement: :system | :history | :tool_context
  #   priority:  Integer; higher = more important (survives cuts)
  #   tokens:    Integer | nil; estimated by the Builder when nil
  #   source:    String — provider id (audit)
  #   pinned:    true -> uncuttable in the budget (e.g. identity)
  #   labels:    [String] — WHAT this fragment carries, as ids (skill names, tool
  #              names). Content-FREE by contract, so the context trace can report
  #              which skills a turn injected without storing a byte of the bodies.
  #              [] = nothing to name (the default for every provider that has no
  #              natural id, e.g. the identity prompt).
  ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                                :source, :pinned, :labels) do
    def self.build(content:, placement:, source:, priority: 50, tokens: nil,
                   pinned: false, labels: [])
      new(content: content, placement: placement, priority: priority,
          tokens: tokens, source: source, pinned: pinned,
          labels: Array(labels).map(&:to_s))
    end
  end
end
