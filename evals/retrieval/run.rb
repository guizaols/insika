# frozen_string_literal: true

# Local, deterministic retrieval comparison. No chat or rerank provider is called.
require_relative "../../lib/insika"
require "json"
require "async"

module RetrievalEval
  ROOT = File.expand_path("golden", __dir__)
  RERANK = { provider: "cohere", model: "rerank-v3.5", candidate_limit: 3, timeout_seconds: 2 }.freeze
  CaseShape = Data.define(:kind, :target, :forbidden, :seed)
  SHAPES = {
    "lexical-ambiguity" => CaseShape.new(:knowledge, "cedar-delivery", ["cedar-sale"],
      [["cedar-sale", "cedar delivery sale", "cedar delivery sale"], ["cedar-delivery", "cedar arrives Tuesday", "delivery detail"]]),
    "older-memory" => CaseShape.new(:memory, "note:older", ["note:newer"], nil),
    "paraphrase-no-overlap" => CaseShape.new(:knowledge, "sofa-care", [],
      [["sofa-care", "vacuum fabric weekly", "upholstery cleaning"]]),
    "empty-results" => CaseShape.new(:knowledge, nil, [], []),
    "expired-fact" => CaseShape.new(:memory, nil, ["fact:retired"], nil),
    "tenant-isolation" => CaseShape.new(:knowledge, "tenant-visible", ["tenant-private"],
      [["tenant-visible", "cedar arrives Tuesday", "delivery detail"]]),
    "provider-failure" => CaseShape.new(:knowledge, "cedar-delivery", [],
      [["cedar-delivery", "cedar arrives Tuesday", "delivery detail"]]),
    "outside-note-window" => CaseShape.new(:memory, "note:oldest", [], nil),
    "deleted-concept" => CaseShape.new(:knowledge, nil, ["deleted-concept"],
      [["deleted-concept", "cedar delivery", "removed answer"]])
  }.freeze

  class Oracle
    attr_reader :documents, :calls

    def initialize(shape:, fail: false)
      @shape, @fail, @documents, @calls = shape, fail, [], 0
    end

    def rerank(_query, documents, **options)
      @calls += 1
      @documents = documents
      raise IOError, "synthetic provider failure" if @fail

      ordered = (0...documents.size).sort_by do |i|
        [documents[i].include?(@shape.target.to_s.delete_prefix("note:")) ? 0 : 1, i]
      end
      Struct.new(:results).new(ordered.first(options.fetch(:top_n)).map { |i| Struct.new(:index).new(i) })
    end
  end

  module_function

  def cases = Insika::Evals::GoldenLoader.load_dir(ROOT)

  def run(repeats: 20)
    cases.to_h do |golden|
      shape = SHAPES.fetch(golden.id)
      readings = { "off" => [], "on" => [] }
      repeats.times do
        %w[off on].each { |mode| readings[mode] << measure(golden, shape, mode == "on") }
      end
      first = readings.transform_values(&:first)
      [golden.id, {
        "candidate_recall" => { "off" => recall(shape, first.fetch("off"), enabled: false),
                                "on" => recall(shape, first.fetch("on"), enabled: true) },
        "off" => summarize(first.fetch("off")), "on" => summarize(first.fetch("on")),
        "latency_ms" => readings.transform_values { |rows| latency(rows) }.merge(
          "added" => latency(readings.fetch("on").zip(readings.fetch("off")).map do |on, off|
            { "latency_ms" => on.fetch("latency_ms") - off.fetch("latency_ms") }
          end)),
        "cost" => readings.transform_values do |rows|
          { "reported_usd" => nil, "unknown_provider_calls" => rows.sum { |row| row.fetch("provider_calls") } }
        end
      }]
    end
  end

  def measure(golden, shape, enabled)
    backend = Insika::Stores::Memory.new
    memory = Insika::MemoryStore.new(store: backend)
    knowledge = Insika::KnowledgeStore.new(store: backend)
    seed(golden, shape, memory, knowledge)
    oracle = Oracle.new(shape: shape, fail: golden.id == "provider-failure")
    config = enabled ? RERANK : nil
    profile = if shape.kind == :memory
                Insika::AgentProfile.build(id: golden.agent, memory: true,
                  memory_retrieval: config && { top_k: 1, rerank: config })
              else
                Insika::AgentProfile.build(id: golden.agent,
                  knowledge: { retrieve: true, top_k: 1 }.merge(config ? { rerank: config } : {}))
              end
    events = []
    request = Insika::ContextRequest.new(session: nil, message: golden.opens_with,
      profile: profile, tenant: golden.tenant, vars: {},
      diagnostics: ->(type, _data) { events << type })
    provider = shape.kind == :memory ? Insika::Context::Providers::Memory.new(store: memory, llm: oracle) :
                                        Insika::Context::Providers::Knowledge.new(store: knowledge, llm: oracle)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fragments = Async { provider.call(request) }.wait
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    content = fragments.map(&:content).join("\n")
    selected = if shape.kind == :knowledge
                 fragments.flat_map { |fragment| fragment.labels.map { |label| label.fetch("name") } }
               else
                 memory_ids(content, golden)
               end
    isolation_safe = golden.id != "tenant-isolation" ||
      !(oracle.documents + [content]).join.include?("PRIVATE_SCOPE_LEAK")
    answer = if shape.kind == :memory
               content[/<note>(.*?)<\/note>/m, 1] || content[/<fact key="[^"]+">(.*?)<\/fact>/m, 1] || "unknown"
             else
               content[/<concept\b[^>]*>(.*?)<\/concept>/m, 1] || "unknown"
             end
    result = Insika::Evals::TurnResult.new(output_text: answer, tool_calls: [], ui: [])
    checks = Insika::Evals::Assertions.evaluate(golden, result)
    { "candidates" => oracle.documents, "selected" => selected, "events" => events,
      "emitted_context" => content, "isolation_safe" => isolation_safe,
      "context_correct" => (shape.target.nil? || selected.include?(shape.target)) &&
        (selected & shape.forbidden).empty? && isolation_safe, "answer_correct" => checks.pass?,
      "provider_calls" => oracle.calls, "latency_ms" => elapsed }
  end

  def seed(golden, shape, memory, knowledge)
    if shape.kind == :memory
      facts = golden.state.dig("memory", "facts") || {}
      facts.each do |key, value|
        expiry = key == "retired" ? "2020-01-01T00:00:00Z" : nil
        memory.put_fact(tenant: golden.tenant, key: key, value: value, expires_at: expiry)
      end
      Array(golden.state.dig("memory", "notes")).each_with_index do |text, i|
        memory.add_note(tenant: golden.tenant, id: text.split.first,
          text: text, at: format("2026-01-%02dT00:00:00Z", i + 1))
      end
      if golden.id == "outside-note-window"
        10.times { |i| memory.add_note(tenant: golden.tenant, id: "new#{i}", text: "new#{i} filler", at: format("2026-02-%02dT00:00:00Z", i + 1)) }
      end
    else
      shape.seed.each do |name, description, body|
        content = Insika::Knowledge::Concept.render(name: name, description: description,
          type: "fact", body: body, provenance: "observed", confidence: name == "cedar-sale" ? 0.95 : 0.6,
          sources: ["fixture"], occurrences: 1, created_at: "2026-09-01T00:00:00Z",
          updated_at: "2026-09-01T00:00:00Z")
        knowledge.write(golden.agent, name, content, tenant: golden.tenant)
      end
      if golden.id == "tenant-isolation"
        private_content = Insika::Knowledge::Concept.render(name: "tenant-private",
          description: "PRIVATE_SCOPE_LEAK cedar delivery", type: "fact", body: "private-only",
          provenance: "observed", confidence: 0.6, sources: ["fixture"], occurrences: 1,
          created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z")
        knowledge.write(golden.agent, "tenant-private", private_content, tenant: "other")
      elsif golden.id == "deleted-concept"
        knowledge.delete(golden.agent, "deleted-concept", tenant: golden.tenant)
      end
    end
  end

  def memory_ids(content, golden)
    ids = (golden.state.dig("memory", "facts") || {}).keys.filter_map do |key|
      "fact:#{key}" if content.include?(%(<fact key="#{key}">))
    end
    notes = Array(golden.state.dig("memory", "notes"))
    notes += 10.times.map { |i| "new#{i} filler" } if golden.id == "outside-note-window"
    ids + notes.filter_map { |text| "note:#{text.split.first}" if content.include?("<note>#{text}</note>") }
  end

  def recall(shape, row, enabled:)
    return "N/A (no relevant record)" if shape.target.nil?
    hit = if enabled
            row.fetch("candidates").any? { |doc| doc.include?(shape.target.delete_prefix("note:")) }
          else
            row.fetch("selected").include?(shape.target)
          end
    hit ? "1/1" : "0/1"
  end

  def summarize(row)
    row.slice("candidates", "selected", "context_correct", "answer_correct", "provider_calls", "events", "isolation_safe")
  end

  def latency(rows)
    values = rows.map { |row| row.fetch("latency_ms") }.sort
    { "p50" => values[values.length / 2].round(3),
      "p95" => values[((values.length * 0.95).ceil - 1)].round(3) }
  end
end

if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate(RetrievalEval.run(repeats: Integer(ARGV.fetch(0, "20"))))
end
