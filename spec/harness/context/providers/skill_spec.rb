# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Harness::Context::Providers::Skill do
  around do |example|
    Dir.mktmpdir { |d| @dir = d; example.run }
  end

  def write_skill(name, description: "desc", body: "body")
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: #{description}\n---\n#{body}\n")
  end

  let(:catalog) { Harness::SkillCatalog.new(@dir) }

  def request(skills:)
    profile = Harness::AgentProfile.build(id: "a", model: "m", skills: skills)
    Harness::ContextRequest.new(session: nil, message: "oi", profile: profile,
                                tenant: nil, vars: {}, checkpoint: nil)
  end

  it "produces 1 :system priority 80 non-pinned fragment == format_for_prompt(effective)" do
    write_skill("cardapio")
    write_skill("pedido")

    frags = described_class.new(catalog: catalog).call(request(skills: nil))

    expect(frags.size).to eq(1)
    f = frags.first
    expect([f.placement, f.priority, f.pinned]).to eq([:system, 80, false])
    expect(f.content).to eq(catalog.format_for_prompt(catalog.effective(nil)))
    expect(f.content).to include("cardapio", "pedido")
  end

  it "respects profile.skills == [] -> no fragment" do
    write_skill("cardapio")
    expect(described_class.new(catalog: catalog).call(request(skills: []))).to eq([])
  end

  it "subset: only the profile's skill appears" do
    write_skill("cardapio")
    write_skill("pedido")

    frag = described_class.new(catalog: catalog).call(request(skills: ["cardapio"])).first

    expect(frag.content).to include("cardapio")
    expect(frag.content).not_to include("pedido")
  end
end
