# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../lib/insika/server/a2a/errors"

RSpec.describe Insika::Server::A2A::Errors do
  it "ValidationError -> INVALID_PARAMS" do
    code, = described_class.from_exception(Insika::ValidationError.new("x"))
    expect(code).to eq(described_class::INVALID_PARAMS)
  end

  it "NotFoundError -> INVALID_PARAMS (task-not-found is handled in the App)" do
    code, = described_class.from_exception(Insika::NotFoundError.new("agente x"))
    expect(code).to eq(described_class::INVALID_PARAMS)
  end

  it "any exception -> INTERNAL_ERROR without leaking the message" do
    code, msg = described_class.from_exception(RuntimeError.new("segredo interno"))
    expect(code).to eq(described_class::INTERNAL_ERROR)
    expect(msg).to eq("internal error")
  end

  it "JSON-RPC/A2A codes match" do
    expect([described_class::PARSE_ERROR, described_class::METHOD_NOT_FOUND, described_class::TASK_NOT_FOUND])
      .to eq([-32_700, -32_601, -32_001])
  end
end
