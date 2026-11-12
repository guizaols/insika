# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Executor context budget" do
  let(:context) { RubyLLM.context { |config| config.deepseek_api_key = "spec-only" } }
  let(:executor) { Insika::Executor.allocate }

  def chat_for(model) = context.chat(model: model, provider: :deepseek, assume_model_exists: true)

  it "budgets tool results for a model whose window the catalog knows" do
    chat = chat_for("deepseek-v4-flash")
    executor.send(:apply_context_budget, chat)
    expect(chat.context_budget).to eq(Insika::Executor::CONTEXT_BUDGET)
  end

  it "leaves a model without a known window unbudgeted (and RubyLLM quiet)" do
    chat = chat_for("not-in-the-catalog")
    executor.send(:apply_context_budget, chat)
    expect(chat.context_budget).to be_nil
  end
end
