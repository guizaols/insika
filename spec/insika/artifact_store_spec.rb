# frozen_string_literal: true

require "spec_helper"

# the report destination store: one record per run, no versioning,
# the listing IS the history. The tenant is a binding of the row (inherited
# from the agent that saved it — never a model-typed parameter), so per-tenant
# scans are prefixes and a purge can never touch a neighbour.
RSpec.describe Insika::ArtifactStore do
  let(:backend) { Insika::Stores::Memory.new }
  subject(:store) { described_class.new(store: backend) }

  let(:now) { Time.iso8601("2026-08-19T12:00:00Z") }
  let(:html) { "<html><body><h1>Daily report</h1></body></html>" }

  def create!(tenant: "acme", agent: "reporter", task_id: "t-1", title: "Daily report",
              mime: "text/html", content: html, id: SecureRandom.uuid, **rest)
    store.create(tenant: tenant, agent: agent, task_id: task_id, title: title,
                 mime: mime, content: content, id: id, now: now, **rest)
  end

  describe "#create" do
    it "stores the record with the given fields; find returns it" do
      record = create!(id: "a-1")
      expect(record.id).to eq("a-1")
      expect(record.tenant).to eq("acme")
      expect(record.agent).to eq("reporter")
      expect(record.task_id).to eq("t-1")
      expect(record.title).to eq("Daily report")
      expect(record.mime).to eq("text/html")
      expect(record.content).to eq(html)
      expect(record.created_at).to eq(now.iso8601)
      expect(store.find("a-1")).to eq(record)
    end

    it "a blank tenant lands in the 'platform' cell (purge prefix alignment)" do
      record = create!(tenant: nil, id: "a-1")
      expect(record.tenant).to eq("platform")
      expect(store.purge(tenant: "platform")).to eq(1)
    end

    it "defaults mime to text/html" do
      expect(create!(mime: nil, id: "a-1").mime).to eq("text/html")
    end

    it "refuses a mime outside the allowlist" do
      expect { create!(mime: "application/pdf", id: "a-1") }
        .to raise_error(Insika::ValidationError, /mime/)
    end

    it "refuses an empty title" do
      expect { create!(title: "", id: "a-1") }
        .to raise_error(Insika::ValidationError, /title/)
    end

    it "refuses a title longer than 200 chars" do
      expect { create!(title: "x" * 201, id: "a-1") }
        .to raise_error(Insika::ValidationError, /title/)
    end

    it "refuses empty content" do
      expect { create!(content: "", id: "a-1") }
        .to raise_error(Insika::ValidationError, /content/)
    end

    it "refuses content over the size cap" do
      expect { create!(content: "x" * 11, id: "a-1", max_bytes: 10) }
        .to raise_error(Insika::ValidationError, /content/)
    end

    it "the default cap is artifact-sized, not chat-sized (a page, not a message)" do
      record = create!(content: "x" * Insika::ArtifactStore::DEFAULT_MAX_BYTES, id: "a-1")
      expect(store.find("a-1")).to eq(record)
    end
  end

  describe "#find" do
    it "nil for an unknown id" do
      expect(store.find("nope")).to be_nil
    end
  end

  describe "#for_agent" do
    it "lists one agent's artifacts, newest first (the listing is the history)" do
      create!(id: "a-old", now: now)
      create!(id: "a-new", now: now + 3600)
      create!(id: "a-mid", now: now + 1800)
      create!(tenant: "loja-b", agent: "reporter", id: "b-1", now: now)

      ids = store.for_agent(tenant: "acme", agent: "reporter").map(&:id)
      expect(ids).to eq(%w[a-new a-mid a-old])
    end

    it "empty for an agent with none" do
      expect(store.for_agent(tenant: "acme", agent: "nobody")).to be_empty
    end
  end

  describe "#delete" do
    it "removes the artifact; false when it does not exist" do
      create!(id: "a-1")
      expect(store.delete("a-1")).to be(true)
      expect(store.find("a-1")).to be_nil
      expect(store.delete("a-1")).to be(false)
    end
  end

  describe "#purge (tenant-erasure reach)" do
    it "removes ONE tenant's artifacts; the neighbour survives" do
      create!(id: "a-1")
      create!(id: "a-2")
      create!(tenant: "loja-b", id: "b-1")

      expect(store.purge(tenant: "acme")).to eq(2)
      expect(store.find("a-1")).to be_nil
      expect(store.find("b-1")).not_to be_nil
    end
  end

  describe "#delete_older_than (the retention knob's reach)" do
    it "removes artifacts whose created_at is older than the cutoff; newer survive" do
      create!(id: "old", now: now - 86_400 * 10)
      create!(id: "new", now: now)

      expect(store.delete_older_than(now - 86_400 * 5)).to eq(1)
      expect(store.find("old")).to be_nil
      expect(store.find("new")).not_to be_nil
    end

    it "an artifact exactly at the cutoff survives (strictly older is removed)" do
      create!(id: "edge", now: now)
      expect(store.delete_older_than(now)).to eq(0)
      expect(store.find("edge")).not_to be_nil
    end
  end
end