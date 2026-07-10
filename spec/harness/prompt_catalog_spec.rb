# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Harness::PromptCatalog do
  around do |example|
    Dir.mktmpdir { |d| @dir = d; example.run }
  end

  def write_prompt(root, name, description: "desc", body: "corpo do prompt", filename: "PROMPT.md")
    path = File.join(root, name)
    FileUtils.mkdir_p(path)
    frontmatter = name.nil? ? "description: #{description}" : "name: #{name}\ndescription: #{description}"
    File.write(File.join(path, filename), "---\n#{frontmatter}\n---\n#{body}\n")
  end

  it "faz parse de PROMPT.md (name/description + corpo sem frontmatter)" do
    write_prompt(@dir, "tom", description: "o tom de voz", body: "Seja gentil.")
    prompt = described_class.new(@dir).find("tom")

    expect(prompt.name).to eq("tom")
    expect(prompt.description).to eq("o tom de voz")
    expect(prompt.body).to eq("Seja gentil.")
    expect(prompt.path).to end_with("PROMPT.md")
  end

  it "precedência de roots: primeiro root vence" do
    root_a = File.join(@dir, "a")
    root_b = File.join(@dir, "b")
    write_prompt(root_a, "tom", body: "de A")
    write_prompt(root_b, "tom", body: "de B")

    expect(described_class.new([root_a, root_b]).find("tom").body).to eq("de A")
  end

  it "find inexistente -> nil" do
    expect(described_class.new(@dir).find("nope")).to be_nil
  end

  it "ignora PROMPT.md sem frontmatter" do
    path = File.join(@dir, "bad")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "PROMPT.md"), "sem frontmatter")
    expect(described_class.new(@dir).all).to eq([])
  end

  it "ignora frontmatter sem name" do
    path = File.join(@dir, "noname")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "PROMPT.md"), "---\ndescription: só descrição\n---\ncorpo\n")
    expect(described_class.new(@dir).all).to eq([])
  end

  it "all lista os prompts válidos" do
    write_prompt(@dir, "tom")
    write_prompt(@dir, "estilo")
    expect(described_class.new(@dir).all.map(&:name)).to contain_exactly("tom", "estilo")
  end

  it "roots inexistentes -> catálogo vazio, sem erro" do
    expect(described_class.new(File.join(@dir, "nao-existe")).all).to eq([])
  end
end
