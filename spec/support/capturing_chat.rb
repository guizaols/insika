# frozen_string_literal: true

require_relative "fake_chat"

# RFC-0036 C5 — the conformance suite's ORACLE chat. FakeChat plus message
# RECORDING in the exact serialized shape the checkpoint persists (string
# keys, tool_calls as [{id, name, arguments}]), so the durable transcript
# equals the provider-visible stream byte-for-byte and the suite can prove
# it. The plain FakeChat deliberately does NOT record the turn (turn_transcript's
# {user, assistant} fallback covers that — pinned by executor_pipeline_spec);
# this subclass is the faithful double of what the provider serializes.
class CapturingChat < FakeChat
  def ask(message, with: nil, &on_chunk)
    add_message(role: "user", content: message)
    super
  end

  def add_message(role:, content:, tool_calls: nil, tool_call_id: nil)
    # content.to_s: the checkpoint's serialize_chat_message renders content as
    # a string ("", never nil) — the oracle must record the same byte.
    msg = { "role" => role.to_s, "content" => content.to_s }
    calls = serialize_calls(tool_calls)
    msg["tool_calls"] = calls unless calls.empty?
    msg["tool_call_id"] = tool_call_id if tool_call_id
    @messages << msg
    self
  end

  def fire_end_message(role: "assistant", content: nil, tool_calls: nil)
    # the `role: tool` message is recorded by the add_message half of
    # fire_tool_result_message — recording it a second time here would
    # duplicate the byte RubyLLM sends once.
    add_message(role: role, content: content, tool_calls: tool_calls) unless role.to_s == "tool"
    super
  end

  private

  def serialize_calls(tool_calls)
    return [] if tool_calls.nil?

    list = tool_calls.is_a?(Hash) ? tool_calls.values : Array(tool_calls)
    list.filter_map do |tc|
      next nil unless tc

      { "id" => (tc.id if tc.respond_to?(:id)),
        "name" => (tc.name if tc.respond_to?(:name)),
        "arguments" => (tc.arguments if tc.respond_to?(:arguments)) }
    end
  end
end