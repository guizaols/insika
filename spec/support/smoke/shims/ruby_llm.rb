# frozen_string_literal: true

# RubyLLM shim loaded into the smoke process via RUBYOPT=-I (the Executor/LoadSkill's
# lazy `require "ruby_llm"` resolves here instead of the real gem). It is TEST
# SCAFFOLDING, not production: it mirrors only the surface the Executor uses
# (create_chat/with_instructions/with_tools/add_message/before_tool_call/
# after_tool_result/ask with a chunks block) — none of the LLM runtime is
# reimplemented. Behavior scripted by ENV.
require "async"

module RubyLLM
  # production config/wiring would call this; the smoke doesn't, but we keep it for
  # robustness (does nothing useful here).
  def self.configure
    yield(Object.new) if block_given?
  end

  # -> fake chat. Signature identical to the one used in Executor#create_chat.
  def self.chat(model:, provider: nil, assume_model_exists: false)
    FakeChat.new
  end

  # Base of the tools (LoadSkill inherits). Only the class methods used in the class
  # DEFINITION (description/param) — in the smoke the profile has no skills, so
  # LoadSkill isn't even instantiated.
  class Tool
    def self.description(_text = nil); end
    def self.param(_name, **_opts); end
    def self.params(*_args, **_opts); end # array-of-objects schema DSL (spawn_subagents)

    # `halt_when`: the Executor tests every response with `is_a?(Tool::Halt)`, so the
    # class must exist here too — without it the smoke turn dies on a NameError that
    # looks like a hang. The smoke never produces one; it only needs to be nameable.
    class Halt
      attr_reader :content

      def initialize(content) = (@content = content)
      def to_s = @content.to_s
    end
  end

  # Scripted chat. Two modes:
  #   trava   (default): emits 1 chunk, writes the SMOKE_TURN_STARTED marker and
  #                      BLOCKS (deterministic window for the kill -9).
  #   complete (SMOKE_MODE=complete): emits 1 chunk and returns the final response.
  class FakeChat
    Response = Struct.new(:content)

    def initialize = (@tools = [])
    def with_instructions(_text) = self
    def add_message(role:, content:) = self
    def before_tool_call(&blk) = (@before = blk) && self
    def after_tool_result(&blk) = (@after = blk) && self

    def with_tools(*tools) = (@tools.concat(tools); self)

    def ask(message, &on_chunk)
      on_chunk&.call(Response.new("processando... "))

      # APPROVAL mode (P2-02): calls the `charge` tool — the ToolEnvelope trips the
      # gate and SUSPENDS the turn in :waiting until the operator approves (the call
      # blocks in here; on approval it executes and returns). Covers slice A's smoke
      # (suspend -> kill -9 -> reboot -> approve -> complete).
      if ENV["SMOKE_APPROVAL"] && (tool = @tools.find { |t| t.name.to_s == "charge" })
        return Response.new("resultado: #{tool.call("amount" => 10)}")
      end

      return Response.new("resposta final para: #{message}") if ENV["SMOKE_MODE"] == "complete"

      # "trava" mode: signals the start of the turn and blocks forever.
      File.write(ENV.fetch("SMOKE_TURN_STARTED"), "started")
      loop { Async::Task.current.sleep(0.1) } # never returns; the kill -9 kills the process
    end
  end
end
