# frozen_string_literal: true

module Insika
  # RFC-0036 C4/D4 — the model-visible payload of ONE ask: the system text,
  # the tool schemas, and the full message stream — exactly what the provider
  # serializes. Captured AT the RubyLLM boundary (the chat object the executor
  # hands to `ask`), never re-derived: re-derivation would re-run volatile
  # context providers (LLM moderation, timestamps) and could drift from the
  # bytes actually sent.
  #
  # "Model-visible means logged": the durable reconstruction of a turn is the
  # checkpoint (messages — the transcript half) + this record (instructions +
  # tool schemas — the half the checkpoint lacks). The conformance suite
  # (spec/insika/conformance/model_visible_spec.rb) asserts the three-way byte
  # identity: capturing chat == checkpoint == trace.
  #
  # Pure reads off the chat object with respond_to? guards — a chat lacking a
  # reader contributes nil/[], never raises (the trace discipline).
  ModelVisible = Data.define(:instructions, :tools, :messages) do
    # -> ModelVisible. `chat` is the RubyLLM chat at the boundary (instructions,
    # tools, messages are exactly the three parts the provider serializes).
    def self.capture(chat)
      new(
        instructions: chat.respond_to?(:instructions) ? chat.instructions : nil,
        tools: chat.respond_to?(:tools) ? Array(chat.tools).map { |t| tool_schema(t) } : [],
        messages: chat.respond_to?(:messages) ? Array(chat.messages) : []
      )
    end

    # -> Hash: the JSON-safe schema of ONE tool. Reads `parameters` then
    # `schema` (the two reader shapes the house FakeChat and the gem's tools
    # answer); a tool answering none degrades to nil, never raises.
    def self.tool_schema(tool)
      params = if tool.respond_to?(:parameters)
                 tool.parameters
               elsif tool.respond_to?(:schema)
                 tool.schema
               end
      {
        "name" => (tool.name.to_s if tool.respond_to?(:name)),
        "description" => (tool.description.to_s if tool.respond_to?(:description)),
        "parameters" => params && json_safe(params)
      }.compact
    end

    # -> JSON-safe projection of an arbitrary schema value. The gem's tools
    # answer parameters as Hash with RubyLLM::Parameter values (a class whose
    # readers are name/type/description/required) — the trace must persist the
    # schema, so it projects that shape instead of raising on the object (the
    # record never breaks the turn). Anything unprojectable degrades to its
    # string form, never raises.
    def self.json_safe(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = json_safe(v) }
      when Array
        value.map { |v| json_safe(v) }
      when String, Integer, Float, TrueClass, FalseClass, NilClass
        value
      else
        if %i[name type description required].all? { |m| value.respond_to?(m) }
          { "name" => value.name.to_s, "type" => value.type.to_s,
            "description" => value.description.to_s, "required" => value.required }
        elsif value.respond_to?(:to_h)
          json_safe(value.to_h)
        else
          value.to_s
        end
      end
    end

    # The store round-trip: a plain Hash (string keys) -> ModelVisible.
    def self.from_h(hash)
      h = hash || {}
      new(
        instructions: h["instructions"],
        tools: Array(h["tools"]),
        messages: Array(h["messages"])
      )
    end

    # JSON-safe (string keys), the shape the store persists.
    def to_h
      { "instructions" => instructions, "tools" => tools, "messages" => messages }
    end
  end
end
