# frozen_string_literal: true

# Requireable RubyLLM stub so the suite runs WITHOUT the gem (doc 03 §7). Only the
# class surface that Harness::Tools::LoadSkill uses at load-time — no runtime
# behavior is reimplemented (RubyLLM First is not violated: this is test
# scaffolding). Lives in spec/support/stubs, which the spec_helper only puts on the
# $LOAD_PATH when the real gem is absent.
module RubyLLM
  class Tool
    def self.description(_text = nil); end
    def self.param(_name, **_opts); end
  end
end
