# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../server/a2a/remotes"

RSpec.describe Harness::Server::A2A::Remotes do
  it "parseia id=url,id2=url2" do
    remotes = described_class.parse("researcher=https://a/a2a,writer=https://b/a2a")
    expect(remotes.map(&:id)).to eq(%w[researcher writer])
    expect(remotes.first.url).to eq("https://a/a2a")
  end

  it "aplica descriptions por id" do
    r = described_class.parse("worker=https://w/a2a", descriptions: { "worker" => "faz contas" })
    expect(r.first.description).to eq("faz contas")
  end

  it "env nil / vazio -> []" do
    expect(described_class.parse(nil)).to eq([])
    expect(described_class.parse("")).to eq([])
  end

  it "ignora entradas malformadas com warn" do
    expect do
      remotes = described_class.parse("ok=https://o/a2a,semigual,vazio=")
      expect(remotes.map(&:id)).to eq(["ok"]) # só a válida
    end.to output(/malformado/).to_stderr
  end

  it "tolera espaços em volta de id/url" do
    r = described_class.parse(" worker = https://w/a2a ")
    expect(r.first).to have_attributes(id: "worker", url: "https://w/a2a")
  end
end
