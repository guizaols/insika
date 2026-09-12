# frozen_string_literal: true

# Did the customer's word actually gate the write?
#
# The cell that answers it is a transcript: turns in order, each carrying the tool
# calls that turn made — `held` from the engine's own `confirmation_requested`
# (a call the store never sees, by definition) and `ok`/`error` from the store's
# append-only log, which is the only authority on what was written.
#
# This reads that evidence and refuses to call a write "confirmed" unless the hold
# is on record AND the write lands on a LATER turn than the hold — that is, after a
# customer message the hold could have been answered by. An empty call list is not a
# hold, and a hold and a write in the same turn are not consent.
module ConfirmationProof
  module_function

  # How a hold ended, as the driver reports it: the two system tools by name, and
  # the engine's own expiry, which is nobody's tool call.
  DECISIONS = { "confirm_pending" => "confirmed", "cancel_pending" => "cancelled",
                "confirmation_expired" => "expired" }.freeze

  # turns -> { "held_turns" =>, "executed_turns" =>, "decisions" =>, "proven" =>, "reason" => }
  # `proven` is only ever true about a write that happened; a scenario where
  # nothing was written says so in `reason` and leaves `proven` false.
  def read(turns, tool: "create_order")
    held = turns_with(turns, tool, "held")
    executed = turns_with(turns, tool, "ok")
    verdict = { "held_turns" => held, "executed_turns" => executed, "decisions" => decisions(turns),
                "proven" => false, "reason" => nil }

    if executed.empty?
      verdict.merge("reason" => held.empty? ? "no #{tool} and no hold" : "held, never executed")
    elsif held.empty?
      verdict.merge("reason" => "#{tool} executed with no hold on record")
    elsif (early = executed.find { |e| held.none? { |h| h < e } })
      verdict.merge("reason" => "#{tool} executed on turn #{early + 1} before any hold the customer could answer")
    elsif executed.size > 1
      verdict.merge("reason" => "#{tool} executed #{executed.size} times")
    else
      verdict.merge("proven" => true)
    end
  end

  # -> [{ "turn" =>, "decision" =>, "pending_id" => }], in the order they happened.
  def decisions(turns)
    Array(turns).each_with_index.flat_map do |t, i|
      Array(t["tool_calls"]).filter_map do |c|
        decision = DECISIONS[c["name"].to_s]
        decision && { "turn" => i + 1, "decision" => decision,
                      "pending_id" => c.dig("arguments", "pending_id") }
      end
    end
  end

  def turns_with(turns, tool, status)
    Array(turns).each_index.select do |i|
      Array(turns[i]["tool_calls"]).any? { |c| c["name"].to_s == tool && c["status"].to_s == status }
    end
  end
end
