# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Insika::Context::Providers::Skill do
  around do |example|
    Dir.mktmpdir { |d| @dir = d; example.run }
  end

  def write_skill(name, description: "desc", body: "body")
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: #{description}\n---\n#{body}\n")
  end

  let(:catalog) { Insika::SkillCatalog.new(@dir) }

  def request(skills:)
    profile = Insika::AgentProfile.build(id: "a", model: "m", skills: skills)
    Insika::ContextRequest.new(session: nil, message: "oi", profile: profile,
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

  # The catalog describes what is NOT loaded yet. An eager skill is already in the
  # prompt in full (SkillTrigger injects it), so listing it here would invite a
  # load_skill call that buys a duplicate.
  describe "eager skills are not advertised" do
    def write_eager(name)
      path = File.join(@dir, name)
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"),
                 "---\nname: #{name}\ndescription: sempre\neager: true\n---\nbody\n")
    end

    it "lists only the lazy skills" do
      write_skill("cardapio")
      write_eager("formato")

      frag = described_class.new(catalog: catalog).call(request(skills: nil)).first

      expect(frag.content).to include("cardapio")
      expect(frag.content).not_to include("formato")
    end

    it "every allowed skill eager -> no fragment (nothing left to advertise)" do
      write_eager("formato")

      expect(described_class.new(catalog: catalog).call(request(skills: nil))).to eq([])
    end

    it "skills_eager on the profile makes the whole catalog eager" do
      write_skill("cardapio")
      eager_profile = Insika::AgentProfile.build(id: "a", model: "m", skills_eager: true)
      req = Insika::ContextRequest.new(session: nil, message: "oi", profile: eager_profile,
                                       tenant: nil, vars: {}, checkpoint: nil)

      expect(described_class.new(catalog: catalog).call(req)).to eq([])
    end
  end
end
