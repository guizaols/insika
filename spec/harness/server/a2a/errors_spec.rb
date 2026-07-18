# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../server/a2a/errors"

RSpec.describe Harness::Server::A2A::Errors do
  it "ValidationError -> INVALID_PARAMS" do
    code, = described_class.from_exception(Harness::ValidationError.new("x"))
    expect(code).to eq(described_class::INVALID_PARAMS)
  end

  it "NotFoundError -> INVALID_PARAMS (task-not-found é tratado no App)" do
    code, = described_class.from_exception(Harness::NotFoundError.new("agente x"))
    expect(code).to eq(described_class::INVALID_PARAMS)
  end

  it "any exception -> INTERNAL_ERROR without leaking the message" do
    code, msg = described_class.from_exception(RuntimeError.new("segredo interno"))
    expect(code).to eq(described_class::INTERNAL_ERROR)
    expect(msg).to eq("internal error")
  end

  it "códigos JSON-RPC/A2A conferem" do
    expect([described_class::PARSE_ERROR, described_class::METHOD_NOT_FOUND, described_class::TASK_NOT_FOUND])
      .to eq([-32_700, -32_601, -32_001])
  end
end
