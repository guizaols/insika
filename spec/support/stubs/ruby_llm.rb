# frozen_string_literal: true

# Requireable RubyLLM stub so the suite runs WITHOUT the gem. Only the
# class surface that Insika::Tools::LoadSkill uses at load-time — no runtime
# behavior is reimplemented (RubyLLM First is not violated: this is test
# scaffolding). Lives in spec/support/stubs, which the spec_helper only puts on the
# $LOAD_PATH when the real gem is absent.
module RubyLLM
  class Tool
    def self.description(_text = nil); end
    def self.parameter(_name, **_opts); end
    def self.parameters(*_args, **_opts); end
  end
end
