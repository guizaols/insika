# frozen_string_literal: true

# Insika public benchmark — NEUTRAL, REPRODUCIBLE, PROVIDER-FREE.
#
# Measures the ENGINE OVERHEAD of a turn: everything the insika does around the
# model — context build, policy, guardrail detectors, chat assembly, the tool
# round-trip, streaming, persistence, checkpoint, the event stream — WITHOUT ever
# calling an LLM provider. The model is replaced by a deterministic in-process
# stub, so a run needs NO API key and is reproducible by anyone with:
#
#     bundle exec ruby scripts/bench.rb
#
# WHY provider-free. A turn's wall-clock is dominated by the provider round-trip,
# which the insika does not control (a real-turn profile showed local assembly
# ~0.05ms and time-to-first-token bounded by the provider). A benchmark that
# called a provider would (a) require a key — not reproducible by third parties,
# (b) name a baseline — not neutral, (c) drown the engine signal in provider
# noise. So this suite isolates and reports ONLY what the insika controls:
#   · per-turn engine latency (p50/p95), split prep / first-token / generation
#     via INSIKA_TURN_TIMING;
#   · engine throughput (turns/s) under concurrency;
#   · engine streaming throughput (tokens/s pushed through the pipeline — NOT
#     model generation speed, which is provider-bound and out of scope).
# See docs/BENCHMARK.md for the full methodology and the current numbers.
#
# It is brand-free by construction: no provider, no deployment, no agent from any
# real product appears here — the scenarios are synthetic.
#
# Scenarios (--scenario, default: all):
#   greeting    a minimal turn: short prompt, no tools — baseline overhead.
#   tool_call   a turn where the agent calls one tool (call + result round-trip).
#   multi_turn  a one-shot carrying N prior messages — overhead as context grows.
#
# Usage:
#   bundle exec ruby scripts/bench.rb [options]
#
# Options:
#   --scenario NAME       one of greeting|tool_call|multi_turn|all   (default: all)
#   --iterations N        measured turns for the latency pass         (default: 200)
#   --warmup N            unmeasured warmup turns                     (default: 20)
#   --concurrency N       concurrent turns per wave (throughput pass) (default: 8)
#   --waves N             waves in the throughput pass                (default: 5)
#   --identity-tokens N   approx size of the agent's system prompt    (default: 2000)
#   --history-turns N     prior messages for the multi_turn scenario  (default: 10)
#   --output-tokens N     tokens the stub streams per turn            (default: 48)
#   --json                emit the results as JSON (for CI gating)
#   --ruby-llm            real RubyLLM Chat with an offline provider; tool_call
#                         executes two tool rounds (no HTTP or provider keys)
#   --help                show this help and exit
#
# The run is hermetic: it forces the in-memory backend (ignores INSIKA_DB) and a
# temp file store, so it never touches a real deployment's volume.

if %w[-h --help].include?(ARGV[0])
  puts File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
           .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit 0
end

# Hermetic + honest timing BEFORE the engine loads: Memory backend (never touch a
# real volume) and the per-turn latency split turned on.
ENV.delete("INSIKA_DB")
ENV.delete("HARNESS_DB") # legacy alias — keep the in-memory backend truly hermetic
ENV["INSIKA_TURN_TIMING"] = "1"

require_relative "../lib/insika"
require "async"

# --- flag parsing (--name value / boolean --name) -----------------------------
BOOL_FLAGS = %w[json help ruby-llm].freeze
VALUE_FLAGS = %w[scenario iterations warmup concurrency waves identity-tokens
                 history-turns output-tokens].freeze

def parse_args(argv)
  args = {}
  i = 0
  while i < argv.length
    tok = argv[i]
    abort "bench: expected a --flag, got #{tok.inspect}" unless tok.start_with?("--")
    key = tok.sub(/^--/, "")
    nxt = argv[i + 1]
    if BOOL_FLAGS.include?(key)
      args[key] = true
      i += 1
    elsif VALUE_FLAGS.include?(key)
      abort "bench: --#{key} needs a value" if nxt.nil? || nxt.start_with?("--")
      args[key] = nxt
      i += 2
    else
      abort "bench: unknown flag --#{key} (see --help)"
    end
  end
  args
end

ARGS = parse_args(ARGV)

def int_arg(key, default)
  return default unless ARGS.key?(key)

  n = Integer(ARGS[key])
  raise ArgumentError if n.negative?

  n
rescue ArgumentError, TypeError
  abort "bench: --#{key} must be a non-negative integer (got #{ARGS[key].inspect})"
end

ITERS      = int_arg("iterations", 200)
WARMUP     = int_arg("warmup", 20)
CONC       = [int_arg("concurrency", 8), 1].max
WAVES      = [int_arg("waves", 5), 1].max
IDENTITY   = int_arg("identity-tokens", 2000)
HISTORY    = int_arg("history-turns", 10)
OUT_TOKENS = [int_arg("output-tokens", 48), 1].max
JSON_OUT   = ARGS.fetch("json", false)
REAL_CHAT  = ARGS.fetch("ruby-llm", false)

ALL_SCENARIOS = %w[greeting tool_call multi_turn].freeze
WANT = ARGS.fetch("scenario", "all")
SCENARIOS = WANT == "all" ? ALL_SCENARIOS : [WANT]
unless (SCENARIOS - ALL_SCENARIOS).empty?
  abort "bench: --scenario must be one of #{ALL_SCENARIOS.join('|')}|all (got #{WANT.inspect})"
end

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Interpolated percentile (same method as scripts/loadtest.rb).
def pct(sorted, p)
  return 0.0 if sorted.empty?

  r = (p / 100.0) * (sorted.length - 1)
  lo = sorted[r.floor]
  hi = sorted[r.ceil]
  (lo + (hi - lo) * (r - r.floor)).round(2)
end

def stats(samples)
  sorted = samples.compact.sort
  { p50: pct(sorted, 50), p95: pct(sorted, 95),
    mean: sorted.empty? ? 0.0 : (sorted.sum / sorted.length).round(2),
    max: sorted.empty? ? 0.0 : sorted.last.round(2), n: sorted.length }
end

# A ~4 chars/token neutral system prompt of the requested size (matches the
# TokenEstimator's own ratio). Generic assistant prose — no brand, no product.
def identity_text(tokens)
  target = tokens * 4
  line = "You are a helpful, precise assistant. Answer clearly, stay on topic, " \
         "ask for missing details, and never invent facts you cannot support. "
  (line * ((target / line.length) + 1))[0, target]
end

# ---------------------------------------------------------------------------
# The provider stub. Implements EXACTLY the RubyLLM chat surface the Executor and
# ChatBuilder touch (with_instructions/with_tools/add_message/before_tool_call/
# after_tool_result/messages/model/ask) — no network, deterministic. A fresh one
# is handed out per turn so the per-turn callbacks are clean.
class StubChat
  Chunk    = Struct.new(:content)
  Message  = Struct.new(:role, :content)
  ToolCall = Struct.new(:name, :arguments, :id)
  # A token-bearing response (duck-typed like RubyLLM::Message) so the engine's
  # usage path runs; the numbers are synthetic and are NOT reported as a claim.
  Tokens = Struct.new(:input, :output, :cache_read, :cache_write, :thinking)
  Response = Struct.new(:content, :tokens, :model)

  def initialize(output_tokens:, tool_call:, input_tokens:)
    @output_tokens = output_tokens
    @tool_call = tool_call
    @input_tokens = input_tokens
    @messages = []
  end

  def with_instructions(_text) = self
  def with_tools(*_tools) = self
  def add_message(attrs) = (@messages << Message.new(attrs[:role], attrs[:content])) && self
  def before_tool_call(&blk) = (@before = blk) && self
  def after_tool_result(&blk) = (@after = blk) && self
  attr_reader :messages
  def model = nil # provider check (anthropic caching) -> false
  def ask_later(_message) = self
  def complete? = true
  def awaiting_approval? = false
  def step(&block) = ask(nil, &block)

  # Simulates one model interaction: an optional single tool round-trip, then a
  # streamed answer of @output_tokens chunks, then the final response.
  def ask(_message)
    if @tool_call
      @before&.call(ToolCall.new("lookup", { "q" => "value" }, "call_1"))
      @after&.call("tool result")
    end
    @output_tokens.times { yield Chunk.new("token ") } if block_given?
    Response.new("done", Tokens.new(@input_tokens, @output_tokens), "stub-model")
  end
end

if REAL_CHAT
  require "ruby_llm"

  # Only the provider is synthetic: Chat owns history, callbacks and tool execution.
  # Native Usage::Tracker supplies model_info before accounting; mirror it here.
  class BenchOffline < RubyLLM::Provider
    COUNTS = Hash.new(0)

    def self.slug = "bench_offline"
    def api_base = "http://benchmark.invalid"
    def preprocess_message(message, **) = message

    def complete(messages, tools:, model:, **)
      COUNTS[:provider_calls] += 1
      results = messages.select { |message| message.role == :tool }
      results.each_with_index do |message, index|
        raise "benchmark tool result missing" unless message.content.to_s.include?("lookup #{index + 1}")
      end
      if results.empty?
        COUNTS[:history_messages] += messages.count { |message| message.content.to_s.start_with?("Prior message ") }
      end

      if tools.key?(:lookup) && results.size < 2
        round = results.size + 1
        call = RubyLLM::ToolCall.new(id: "call_#{round}", name: "lookup", arguments: { "q" => round.to_s })
        return RubyLLM::Message.new(role: :assistant, content: "", tool_calls: { call.id => call },
                                    model: model.id, tokens: RubyLLM::Tokens.new(input: IDENTITY, output: 1)).tap { |message| message.model_info = model }
      end

      OUT_TOKENS.times do
        yield RubyLLM::Chunk.new(role: :assistant, content: "token ")
        COUNTS[:streamed_chunks] += 1
      end
      RubyLLM::Message.new(role: :assistant, content: "token " * OUT_TOKENS,
                           model: model.id, tokens: RubyLLM::Tokens.new(input: IDENTITY, output: OUT_TOKENS)).tap { |message| message.model_info = model }
    end
  end

  class BenchLookup < RubyLLM::Tool
    description "Deterministic, offline benchmark lookup."
    parameter :q, type: :string, description: "Lookup number"

    def name = "lookup"

    def execute(q:)
      BenchOffline::COUNTS[:tool_calls] += 1
      "lookup #{q}"
    end
  end

  RubyLLM::Provider.register(:bench_offline, BenchOffline)
end

# ---------------------------------------------------------------------------
# One scenario: a DSL-built agent (the public Insika.agent {} path — same import
# round-trip a real deployment uses) with its create_chat swapped for a StubChat.
class Scenario
  attr_reader :name

  def initialize(name)
    @name = name
    @definition = build_definition
    @graph = @definition.runtime.graph # builds the graph + imports the pack
    if REAL_CHAT
      @graph.code_tool_registry.register("lookup") { BenchLookup.new } if name == "tool_call"
    else
      install_stub
    end
  end

  # The turn payload for this scenario (agent + message + optional history).
  def payload(idx)
    p = { agent: @definition.id, message: "request ##{idx}" }
    p[:history] = history if @name == "multi_turn"
    p
  end

  def bus = @graph.bus
  def event_stream = @graph.event_stream
  def executor = @graph.executor

  private

  def build_definition
    name = @name
    ident = identity_text(IDENTITY)
    Insika.agent("bench-#{name}") do
      model "stub-model"
      provider(REAL_CHAT ? "bench_offline" : "stub")
      instructions "Synthetic benchmark agent (#{name})."
      prompt_file "IDENTITY.md", ident
      if name == "tool_call" && REAL_CHAT
        tools "lookup"
      elsif name == "tool_call"
        data_tool(
          name: "lookup",
          description: "Synthetic lookup tool used only to exercise the tool path.",
          parameters: { "type" => "object",
                        "properties" => { "q" => { "type" => "string" } } },
          request: { "method" => "GET", "url" => "https://example.com/lookup?q={{q}}" }
        )
      end
    end
  end

  # Swap the single RubyLLM boundary for the stub — fresh per turn.
  def install_stub
    tool = @name == "tool_call"
    out = OUT_TOKENS
    inp = IDENTITY # representative prefix size (synthetic)
    @graph.executor.define_singleton_method(:create_chat) do |*_a, **_k|
      StubChat.new(output_tokens: out, tool_call: tool, input_tokens: inp)
    end
  end

  def history
    @history ||= Array.new(HISTORY) do |i|
      role = i.even? ? "user" : "assistant"
      { role: role, content: "Prior message #{i} in the conversation so far." }
    end
  end
end

# ---------------------------------------------------------------------------
# Drives turns through the bus and collects terminal events. One subscription
# (no filter) drained by a consumer fiber; turns are matched by task_id.
class Driver
  TERMINAL = %i[task_completed task_failed task_cancelled].freeze

  def initialize(scenario, parent)
    @scenario = scenario
    @parent = parent
    @terminal = {} # task_id => { ok:, timing: }
    @sub = scenario.event_stream.subscribe
    @consumer = parent.async do
      @sub.each do |ev|
        next unless TERMINAL.include?(ev.type)

        tid = ev.meta && ev.meta[:task_id]
        @terminal[tid] = { ok: ev.type == :task_completed, timing: ev.data[:timing] }
      end
    end
  end

  # Fire one turn; returns its task_id (does not wait).
  def dispatch(idx)
    res = @scenario.bus.dispatch(
      Insika::Command.build(:send_message, @scenario.payload(idx), transport: :cli)
    )
    res[:task_id]
  end

  # Block (cooperatively) until every id has a terminal event.
  def await(ids)
    until ids.all? { |id| @terminal.key?(id) }
      @parent.sleep(0.001)
    end
    ids.map { |id| @terminal[id] }
  end

  def stop
    @sub.close
    @consumer.wait
  end
end

# ---------------------------------------------------------------------------
# Run one scenario: a sequential latency pass (precise per-turn timing) and a
# concurrent throughput pass (wall-clock turns/s).
def run_scenario(name)
  BenchOffline::COUNTS.clear if REAL_CHAT
  scenario = Scenario.new(name)
  latency = nil
  throughput = nil
  allocations = nil
  errors = 0

  Async do |parent|
    driver = Driver.new(scenario, parent)

    # Warmup — JIT / lazy init / page cache, not measured.
    WARMUP.times { |i| driver.await([driver.dispatch(-(i + 1))]) }
    allocated_before = GC.stat(:total_allocated_objects)

    # Latency pass: one turn at a time; timing comes from INSIKA_TURN_TIMING
    # (monotonic, provider-free), not wall-clock, so scheduler noise stays out.
    totals = []
    preps = []
    ttfts = []
    gens = []
    ITERS.times do |i|
      res = driver.await([driver.dispatch(i)]).first
      errors += 1 unless res[:ok]
      t = res[:timing] || {}
      totals << t[:total_ms]
      preps  << t[:prep_ms]
      ttfts  << t[:ttft_ms]
      gens   << t[:gen_ms]
    end
    latency = { total: stats(totals), prep: stats(preps),
                ttft: stats(ttfts), gen: stats(gens) }

    # Throughput pass: CONC turns per wave, WAVES waves; wall-clock turns/s.
    completed = 0
    started = mono
    WAVES.times do |w|
      ids = Array.new(CONC) { |c| driver.dispatch(ITERS + w * CONC + c) }
      driver.await(ids).each { |r| completed += 1; errors += 1 unless r[:ok] }
    end
    wall = mono - started
    allocated = GC.stat(:total_allocated_objects) - allocated_before
    allocations = { total: allocated, per_turn: (allocated.to_f / (ITERS + completed)).round(1) }
    gen_p50 = latency.dig(:gen, :p50)
    # Pipeline cost per streamed token (µs) — the insika's own per-token work
    # (filter/emit/event stream), NOT model generation speed (provider-bound).
    per_token_us = gen_p50 ? (gen_p50 * 1000.0 / OUT_TOKENS).round(2) : nil
    throughput = { turns_per_s: (completed / wall).round(1), wall_s: wall.round(2),
                   completed: completed, concurrency: CONC,
                   per_token_overhead_us: per_token_us }

    driver.stop
    scenario.executor.stop_session_actors
  end

  result = { scenario: name, errors: errors, latency: latency, throughput: throughput, allocations: allocations }
  result[:ruby_llm_activity] = BenchOffline::COUNTS.dup if REAL_CHAT
  result
end

# ---------------------------------------------------------------------------
results = SCENARIOS.map { |s| run_scenario(s) }

if JSON_OUT
  require "json"
  puts JSON.pretty_generate(
    engine: "insika #{Insika::VERSION}",
    mode: REAL_CHAT ? "ruby_llm" : "stub",
    ruby_llm: REAL_CHAT ? Gem.loaded_specs.fetch("ruby_llm").version.to_s : nil,
    ruby: RUBY_DESCRIPTION,
    yjit: (defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?),
    config: { iterations: ITERS, warmup: WARMUP, concurrency: CONC, waves: WAVES,
              identity_tokens: IDENTITY, history_turns: HISTORY, output_tokens: OUT_TOKENS },
    note: REAL_CHAT ? "Offline RubyLLM Chat benchmark; includes Chat/tool-loop overhead, excludes HTTP and provider latency." :
          "provider-free engine benchmark; latency = insika overhead only (no model call). See docs/BENCHMARK.md.",
    results: results
  )
  exit 0
end

yjit = (defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?) ? "YJIT" : "no-YJIT"
puts "insika bench — engine overhead, provider-free (no LLM call)"
puts "RubyLLM #{Gem.loaded_specs.fetch('ruby_llm').version}: real Chat, offline provider; includes Chat/tool-loop overhead" if REAL_CHAT
puts "engine #{Insika::VERSION} · #{RUBY_ENGINE} #{RUBY_VERSION} (#{yjit})"
puts "config: iters=#{ITERS} warmup=#{WARMUP} conc=#{CONC} waves=#{WAVES} " \
     "identity=#{IDENTITY}tok history=#{HISTORY} out=#{OUT_TOKENS}tok"
results.each do |r|
  l = r[:latency]
  t = r[:throughput]
  puts "-" * 66
  puts "scenario: #{r[:scenario]}   (errors: #{r[:errors]})"
  puts "  per-turn engine latency (ms), n=#{l[:total][:n]}:"
  printf("    total  p50=%8.3f  p95=%8.3f  mean=%8.3f  max=%8.3f\n",
         l[:total][:p50], l[:total][:p95], l[:total][:mean], l[:total][:max])
  printf("    prep   p50=%8.3f  p95=%8.3f   (context build + policy + chat assembly)\n",
         l[:prep][:p50], l[:prep][:p95])
  printf("    ttft   p50=%8.3f  p95=%8.3f   (assembly -> first streamed token)\n",
         l[:ttft][:p50], l[:ttft][:p95])
  printf("    gen    p50=%8.3f  p95=%8.3f   (streaming the rest through the pipeline)\n",
         l[:gen][:p50], l[:gen][:p95])
  puts "  throughput (concurrency=#{t[:concurrency]}):"
  puts "    #{t[:turns_per_s]} turns/s over #{t[:wall_s]}s (#{t[:completed]} turns)"
  puts "    allocations: #{r[:allocations][:per_turn]} objects/turn (includes benchmark driver)"
  puts "    pipeline overhead: #{t[:per_token_overhead_us] || '-'} µs/token " \
       "(insika per-token work — NOT model generation speed, which is provider-bound)"
end
puts "-" * 66
puts "Provider excluded by design — see docs/BENCHMARK.md for methodology."
