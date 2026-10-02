# frozen_string_literal: true

# RubyLLM shares one prebuilt Faraday connection per process and settings, so
# swapping the adapter on a connection it already built has no effect. These
# helpers point the next connections RubyLLM builds at a Test adapter that
# answers from the given stubs, keeping RubyLLM's own middleware (retries,
# error mapping, JSON parsing) in front of it.
module LLMHTTPStubs
  def stub_llm_http(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    adapter = Class.new(Faraday::Adapter::Test) do
      define_method(:initialize) { |app, *| super(app, stubs) }
    end
    allow(RubyLLM::Transport::Connection).to receive(:build).and_wrap_original do |build, settings|
      build.call(settings.dup.tap { |stubbed| stubbed.adapter = adapter })
    end
    RubyLLM::Transport::Connection.cache.clear
  end
end

RSpec.configure do |config|
  config.include LLMHTTPStubs
  # A stubbed connection stays cached under the real settings; never let it
  # reach the next example.
  config.after do
    RubyLLM::Transport::Connection.cache.clear if defined?(RubyLLM::Transport::Connection.cache)
  end
end
