# frozen_string_literal: true

module Insika
  # Unit of context produced by a provider.
  # SHARED type (Insika::, not Insika::Context::).
  #   placement: :system | :history | :tool_context
  #   priority:  Integer; higher = more important (survives cuts)
  #   tokens:    Integer | nil; estimated by the Builder when nil
  #   source:    String — provider id (audit)
  #   pinned:    true -> uncuttable in the budget (e.g. identity)
  #   layer:     :identity | :volatile | nil. Stamped by the Builder
  #              at production from the provider's declaration; nil (a fragment
  #              built outside the Builder) reads as :volatile everywhere it is
  #              consumed — parity, never a crash.
  #   labels:    [{ "name" =>, "reason" => }] — WHAT this fragment carries and WHY,
  #              as ids. Content-FREE by contract, so the context trace can report
  #              which skills a turn injected without storing a byte of the bodies.
  #              [] = nothing to name (the default for every provider that has no
  #              natural id, e.g. the identity prompt).
  #
  #              The REASON is the point. A name alone answers "was something
  #              injected"; the operator's actual question is "which skill did I
  #              trigger, and why is it here" — `eager` (the agent always wants it),
  #              `trigger:<matched phrase>` (this message asked for it), or absent
  #              for a body a plugin supplied. String keys because these labels are
  #              written to the context trace and to events as JSON: the round-trip
  #              is then the identity, and no reader has to defend against both.
  ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                                :source, :pinned, :labels, :layer) do
    def self.build(content:, placement:, source:, priority: 50, tokens: nil,
                   pinned: false, labels: [], layer: nil)
      new(content: content, placement: placement, priority: priority,
          tokens: tokens, source: source, pinned: pinned,
          labels: Array(labels).map { |l| label(l) }, layer: layer)
    end

    # A bare String is still a valid label (a provider that has an id but no reason
    # to give) — it normalizes to a reason-less entry rather than being rejected.
    def self.label(raw)
      return { "name" => raw.to_s }.freeze unless raw.is_a?(Hash)

      name = (raw[:name] || raw["name"]).to_s
      reason = raw[:reason] || raw["reason"]
      { "name" => name, "reason" => reason&.to_s }.compact.freeze
    end
  end
end
