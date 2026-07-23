# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../server/a2a/remotes"

RSpec.describe Insika::Server::A2A::Remotes do
  it "parses id=url,id2=url2" do
    remotes = described_class.parse("researcher=https://a/a2a,writer=https://b/a2a")
    expect(remotes.map(&:id)).to eq(%w[researcher writer])
    expect(remotes.first.url).to eq("https://a/a2a")
  end

  it "applies descriptions by id" do
    r = described_class.parse("worker=https://w/a2a", descriptions: { "worker" => "faz contas" })
    expect(r.first.description).to eq("faz contas")
  end

  it "env nil / empty -> []" do
    expect(described_class.parse(nil)).to eq([])
    expect(described_class.parse("")).to eq([])
  end

  it "ignores malformed entries with a warning" do
    expect do
      remotes = described_class.parse("ok=https://o/a2a,noequals,empty=")
      expect(remotes.map(&:id)).to eq(["ok"]) # only the valid one
    end.to output(/malformed/).to_stderr
  end

  it "tolerates spaces around id/url" do
    r = described_class.parse(" worker = https://w/a2a ")
    expect(r.first).to have_attributes(id: "worker", url: "https://w/a2a")
  end
end
