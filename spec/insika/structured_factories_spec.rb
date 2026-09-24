# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Native structured utility responses" do
  [
    [Insika::Distill::DistillerFactory, :distill, { prompt: "facts", message_count: 3 }, :proposals],
    [Insika::Harvest::MinerFactory, :mine, { prompt: "skills", message_counts: [3] }, :skills],
    [Insika::Knowledge::ExtractorFactory, :extract, { prompt: "concepts" }, :concepts]
  ].each do |factory, operation, arguments, result_key|
    it "requests a JSON object and reads native parsed items for #{operation}" do
      llm = double("context")
      chat = double("chat")
      answer = double("response", parsed: { "items" => [] })
      expect(llm).to receive(:chat).with(model: "model", provider: "deepseek", assume_model_exists: true).and_return(chat)
      expect(chat).to receive(:with_temperature).with(0).and_return(chat)
      expect(chat).to receive(:with_schema).with(hash_including("schema" => hash_including("type" => "object"))).and_return(chat)
      expect(chat).to receive(:ask).with(include('"items"', "JSON")).and_return(answer)
      instance = factory.build({}, utility_model: "deepseek/model", llm: llm)
      expect(instance.public_send(operation, **arguments)[result_key]).to eq([])
    end
  end

  it "uses a separate verdict schema for consolidation" do
    llm = double("context")
    chat = double("chat")
    expect(llm).to receive(:chat).and_return(chat)
    expect(chat).to receive(:with_temperature).with(0).and_return(chat)
    expect(chat).to receive(:with_schema).with(hash_including("schema" => Insika::Knowledge::Consolidator::VERDICT_SCHEMA.json_schema)).and_return(chat)
    expect(chat).to receive(:ask).and_return(double("response", parsed: { "verdict" => "related", "merged_body" => "Both claims." }))
    consolidator = Insika::Knowledge::ConsolidatorFactory.build({}, utility_model: "deepseek/model", llm: llm)
    expect(consolidator.resolve(existing_body: "One.", new_body: "Two.")).to eq(verdict: :related, merged_body: "Both claims.")
  end

  it "requests a candidate schema and reads native parsed edits" do
    llm = double("context")
    chat = double("chat")
    expect(llm).to receive(:chat).and_return(chat)
    expect(chat).to receive(:with_temperature).with(0).and_return(chat)
    expect(chat).to receive(:with_schema).with(hash_including("schema" => hash_including("required" => ["edits"]))).and_return(chat)
    expect(chat).to receive(:ask).and_return(double("response", parsed: { "edits" => [] }))
    proposer = Insika::Refinement::ProposerFactory.build({}, utility_model: "deepseek/model", llm: llm)
    expect(proposer.propose(agent_id: "a", findings: [{ "kind" => "error" }], files: { "TOOLS.md" => "Tools" })["edits"]).to eq([])
  end

  it "still rejects forged ownership and invalid evidence in native parsed facts" do
    response = RubyLLM::Message.new(role: :assistant, content: JSON.generate("items" => [
      { "name" => "size", "value" => "M", "scope" => "another-customer" },
      { "name" => "size", "value" => "M", "turns" => [99] },
      { "name" => "size", "value" => "M" }
    ]))
    result = Insika::Distill::Distiller.new(ask: ->(_) { response }).distill(prompt: "p", message_count: 2)
    expect(result[:proposals]).to eq([{ "name" => "size", "value" => "M" }])
    expect(result[:dropped]).to include("unknown_key" => 1, "bad_turns" => 1)
  end

  it "treats malformed native JSON as unusable without trying to extract fenced text" do
    response = RubyLLM::Message.new(role: :assistant, content: '```json {"items": []} ```')
    distiller = Insika::Distill::Distiller.new(ask: ->(_) { response })
    expect { distiller.distill(prompt: "p", message_count: 2) }.to raise_error(Insika::Distill::Distiller::Unusable)
    consolidator = Insika::Knowledge::Consolidator.new(ask: ->(_) { response })
    expect(consolidator.resolve(existing_body: "one", new_body: "two")).to eq(verdict: :contradicting)
  end

  it "keeps DeepSeek's native JSON-object downgrade compatible with the envelope" do
    context = RubyLLM.context { |config| config.deepseek_api_key = "test-key" }
    chat = context.chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true)
    allow(context).to receive(:chat).and_return(chat)
    expect(chat).to receive(:ask) do |prompt|
      protocol = RubyLLM::Providers::DeepSeek::ChatCompletions.new(chat.provider, chat.model)
      payload = protocol.send(:render_payload,
        [RubyLLM::Message.new(role: :user, content: prompt)], tools: {}, temperature: 0,
        model: chat.model, schema: chat.schema
      )
      expect(payload[:response_format]).to eq(type: "json_object")
      expect(chat.schema[:schema][:properties][:items][:type]).to eq("array")
      RubyLLM::Message.new(role: :assistant, content: '{"items": []}')
    end
    distiller = Insika::Distill::DistillerFactory.build({}, utility_model: "deepseek/deepseek-chat", llm: context)
    expect(distiller.distill(prompt: "Facts", message_count: 2)[:proposals]).to eq([])
  end
end
