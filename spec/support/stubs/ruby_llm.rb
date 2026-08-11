# frozen_string_literal: true

# Requireable RubyLLM stub so the suite runs WITHOUT the gem. Only the
# class surface that Insika::Tools::LoadSkill uses at load-time — no runtime
# behavior is reimplemented (RubyLLM First is not violated: this is test
# scaffolding). Lives in spec/support/stubs, which the spec_helper only puts on the
# $LOAD_PATH when the real gem is absent.
module RubyLLM
  class Tool
    def self.description(_text = nil); end
    def self.param(_name, **_opts); end

    # `halt_when`: DataDefinedTool returns one of these and the Executor branches on
    # it. Mirrors the gem's shape (content-only value object) so the suite behaves the
    # same with and without the real gem.
    class Halt
      attr_reader :content

      def initialize(content) = (@content = content)
      def to_s = @content.to_s
    end
  end
end
