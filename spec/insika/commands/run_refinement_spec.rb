# frozen_string_literal: true

require "spec_helper"

# the ONE way a refinement run starts (CLI, Studio button and any
# external cron all dispatch this command — a run starts because a person or a
# schedule asked for one).
RSpec.describe Insika::Commands::RunRefinement do
  subject(:handler) do
    described_class.new(profiles: profiles, refinement_store: runs,
                        collector: collector, event_stream: stream)
  end

  let(:runs) { Insika::RefinementStore.new(store: Insika::Stores::Memory.new) }
  let(:profiles) { { "bia" => profile } }
  let(:profile) { Insika::AgentProfile.build(id: "bia", model: "m", refinement: refinement) }
  let(:refinement) { nil }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  # Records the kwargs it was called with and returns a report — the collector is
  # covered by its own spec; what matters here is WHICH window it is asked for.
  let(:collector) do
    Class.new do
      attr_reader :calls

      def initialize(findings) = (@findings = findings; @calls = [])

      def collect(**kwargs)
        @calls << kwargs
        Insika::Refinement::EvidenceCollector::Report.new(
          agent_id: kwargs[:agent_id], window: {}, findings: @findings,
          sessions_seen: 3, turns_seen: 7, excluded: 0
        )
      end
    end.new(findings)
  end

  let(:findings) do
    [Insika::Refinement::EvidenceCollector::Finding.new(
      kind: :tool_error, key: "tool_error:x:boom", title: "x failed: boom",
      count: 2, severity: 3, sessions: %w[s1], detail: nil
    )]
  end

  def cmd(payload) = Insika::Command.build(:run_refinement, payload)

  it "records the report and answers with the completed run" do
    run = handler.call(cmd({ "agent" => "bia" }))

    expect(run.status).to eq(:completed)
    expect(run.agent_id).to eq("bia")
    expect(run.findings.first["key"]).to eq("tool_error:x:boom")
    expect(runs.latest_for("bia").id).to eq(run.id)
  end

  it "emits :refinement_started then :refinement_report with counts only" do
    handler.call(cmd({ "agent" => "bia" }))

    expect(events.map(&:type)).to eq(%i[refinement_started refinement_report])
    report = events.last.data
    expect(report[:findings]).to eq(1)
    expect(report[:sessions]).to eq(3)
    expect(report[:turns]).to eq(7)
    expect(report.to_s).not_to include("tool_error:x:boom") # counts, never content
  end

  it "an empty report is :no_findings, not a failure" do
    allow(collector).to receive(:collect).and_return(
      Insika::Refinement::EvidenceCollector::Report.new(
        agent_id: "bia", window: {}, findings: [], sessions_seen: 0, turns_seen: 0, excluded: 0
      )
    )

    expect(handler.call(cmd({ "agent" => "bia" })).status).to eq(:no_findings)
  end

  describe "window resolution" do
    it "an explicit since wins over everything" do
      handler.call(cmd({ "agent" => "bia", "since" => "2026-08-01T00:00:00Z" }))

      expect(collector.calls.last[:since]).to eq("2026-08-01T00:00:00Z")
      expect(runs.latest_for("bia").window).to eq("since" => "2026-08-01T00:00:00Z")
    end

    it "an explicit last_sessions is honored (and coerced to an Integer)" do
      handler.call(cmd({ "agent" => "bia", "last_sessions" => "25" }))

      expect(collector.calls.last[:last_sessions]).to eq(25)
    end

    it "defaults to INCREMENTAL: since the previous run for this agent" do
      first = runs.create(agent_id: "bia", at: "2026-08-04T09:00:00Z")
      runs.complete(first.id, findings: [])

      handler.call(cmd({ "agent" => "bia" }))

      expect(collector.calls.last[:since]).to eq("2026-08-04T09:00:00Z")
    end

    context "with a configured window" do
      let(:refinement) { { "window" => { "last_sessions" => 50 } } }

      it "is used on a first run" do
        handler.call(cmd({ "agent" => "bia" }))
        expect(collector.calls.last[:last_sessions]).to eq(50)
      end

      it "full ignores the previous run and falls back to it" do
        runs.complete(runs.create(agent_id: "bia", at: "2026-08-04T09:00:00Z").id, findings: [])

        handler.call(cmd({ "agent" => "bia", "full" => "1" })) # "1" = the Studio checkbox

        expect(collector.calls.last).not_to have_key(:since)
        expect(collector.calls.last[:last_sessions]).to eq(50)
      end
    end

    it "with neither config nor a previous run, the collector's own default applies" do
      handler.call(cmd({ "agent" => "bia" }))
      expect(collector.calls.last).to eq({ agent_id: "bia", max_findings: 20, exclude_sessions: [] })
    end
  end

  describe "configuration" do
    context "when the agent configures max_findings" do
      let(:refinement) { { "max_findings" => 3 } }

      it "caps the report there" do
        handler.call(cmd({ "agent" => "bia" }))
        expect(collector.calls.last[:max_findings]).to eq(3)
      end
    end

    it "needs NO opt-in: an agent without a refinement block still reports" do
      expect(handler.call(cmd({ "agent" => "bia" })).status).to eq(:completed)
    end

    context "when the mode is a typo" do
      let(:refinement) { { "mode" => "propse" } }

      it "refuses instead of silently degrading to report" do
        expect { handler.call(cmd({ "agent" => "bia" })) }
          .to raise_error(Insika::ValidationError, /unknown refinement mode: propse/)
        expect(runs.latest_for("bia")).to be_nil # nothing recorded
      end
    end
  end

  it "agent is required and must exist" do
    expect { handler.call(cmd({})) }.to raise_error(Insika::ValidationError, /agent is required/)
    expect { handler.call(cmd({ "agent" => "ghost" })) }.to raise_error(Insika::NotFoundError, /ghost/)
  end

  it "a collector blowing up leaves the run :failed with the reason, and re-raises" do
    allow(collector).to receive(:collect).and_raise(Insika::StoreError, "disk gone")

    expect { handler.call(cmd({ "agent" => "bia" })) }.to raise_error(Insika::StoreError, /disk gone/)

    failed = runs.latest_for("bia")
    expect(failed.status).to eq(:failed)
    expect(failed.error).to eq("disk gone")
    expect(events.map(&:type)).to eq([:refinement_started]) # no report was produced
  end
end
