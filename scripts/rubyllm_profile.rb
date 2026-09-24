# frozen_string_literal: true

# Standalone offline reproduction; intentionally does not load Insika.
# ruby scripts/rubyllm_profile.rb 2.0.0 [--request-context] [--profile]
require "json"
require "benchmark"

gem "ruby_llm", ARGV.fetch(0, "2.0.0")
require "ruby_llm"

v2 = Gem::Version.new(RubyLLM::VERSION) >= Gem::Version.new("2.0")
request_context = ARGV.include?("--request-context")
profile = ARGV.include?("--profile")
iterations = Integer(ENV.fetch("ITERATIONS", "1000"))
raise "ITERATIONS must be positive" unless iterations.positive?

measurements = Hash.new { |h, k| h[k] = { calls: 0, ms: 0.0 } }
if profile
  { RubyLLM::Models => [:find], RubyLLM::Message => [:model_info],
    RubyLLM::Chat => [:record_out_of_band_usage] }.each do |klass, methods|
    methods.each do |name|
      next unless klass.method_defined?(name) || klass.private_method_defined?(name)

      key = "#{klass}##{name}"
      klass.prepend(Module.new do
        define_method(name) do |*args, **kwargs, &block|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            super(*args, **kwargs, &block)
          ensure
            measurements[key][:calls] += 1
            measurements[key][:ms] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
          end
        end
      end)
    end
  end
end

provider = Class.new(RubyLLM::Provider) do
  define_singleton_method(:slug) { "profile_offline" }
  define_method(:api_base) { "http://offline.invalid" }
  define_method(:preprocess_message) { |message, **| message }
  define_method(:complete) do |messages, model:, **|
    @calls = @calls.to_i + 1
    round = messages.count { |message| message.role == :tool }
    attrs = { role: :assistant, content: round < 2 ? "" : "done" }
    if round < 2
      id = "call-#{round}"
      attrs[:tool_calls] = { id => RubyLLM::ToolCall.new(id: id, name: "lookup", arguments: { "query" => id }) }
    end
    if v2
      attrs.merge!(model: model.id, tokens: RubyLLM::Tokens.new(input: 12, output: 3))
    else
      attrs.merge!(model_id: model.id, input_tokens: 12, output_tokens: 3)
    end
    RubyLLM::Message.new(**attrs).tap do |message|
      # Match Accounting::Usage::Tracker#succeed on native providers.
      message.model_info = model if v2 && request_context
    end
  end
  attr_reader :calls
end
Object.const_set(:ProfileOffline, provider)
RubyLLM::Provider.register(:profile_offline, provider)
lookup = Class.new(RubyLLM::Tool) do
  if v2
    parameter :query, description: "Lookup key"
  else
    param :query, desc: "Lookup key"
  end
  def name = "lookup"
  def execute(query:) = "result #{query}"
end

run = lambda do
  chat = RubyLLM.chat(model: "profile-custom", provider: :profile_offline, assume_model_exists: true)
  chat.with_tools(lookup.new)
  result = chat.ask("request")
  raise "wrong output" unless result.content == "done"
  raise "wrong request count" unless chat.instance_variable_get(:@provider).calls == 3
  raise "wrong history" unless chat.messages.map(&:role) == %i[user assistant tool assistant tool assistant]
  if v2
    raise "missing accounting" unless chat.tokens.input == 36 && chat.tokens.output == 9
  end
end

30.times { run.call }
measurements.clear
GC.start
allocated = GC.stat(:total_allocated_objects)
samples = Array.new(iterations) { Benchmark.realtime { run.call } * 1000 }.sort
allocated = GC.stat(:total_allocated_objects) - allocated
if profile && v2
  expected = iterations * (request_context ? 1 : 4)
  raise "unexpected registry lookups" unless measurements.fetch("RubyLLM::Models#find")[:calls] == expected
end
puts JSON.pretty_generate(version: RubyLLM::VERSION, request_context: request_context, profile: profile,
                          iterations: iterations, p50_ms: samples[iterations / 2],
                          p95_ms: samples[(iterations * 0.95).floor],
                          objects_per_turn: allocated.fdiv(iterations),
                          provider_calls_per_turn: 3, tool_calls_per_turn: 2,
                          measured_methods: measurements)
