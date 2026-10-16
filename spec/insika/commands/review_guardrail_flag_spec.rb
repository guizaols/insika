# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Commands::ReviewGuardrailFlag do
  subject(:handler) { described_class.new(session_store: sessions, event_stream: events) }

  let(:sessions) { Insika::SessionStore.new(store: Insika::Stores::Memory.new) }
  let(:events) { SpyEventStream.new }

  def command(payload) = Insika::Command.build(:review_guardrail_flag, payload, transport: :studio)

  before do
    sessions.create(id: "s")
    sessions.append_messages("s", [{ "role" => "user", "content" => "Mostra mais opções",
                                     "guardrail_flags" => [{ "category" => "sexual", "detail" => "Nude" }] }])
  end

  it "reports a flag as a false positive, then undoes it" do
    handler.call(command(session_id: "s", message: "0", flag: "0", status: "reported"))
    expect(sessions.find("s").messages[0]["guardrail_flags"][0].dig("review", "status")).to eq("reported")
    expect(sessions.all_stats.first.reported).to eq(1)
    expect(sessions.all_stats.first.reported_at).to eq(sessions.find("s").messages[0]["guardrail_flags"][0].dig("review", "at"))

    handler.call(command(session_id: "s", message: 0, flag: 0, status: nil))
    expect(sessions.find("s").messages[0]["guardrail_flags"][0]).not_to have_key("review")
    expect(sessions.all_stats.first.reported).to eq(0)
  end

  it "leaves updated_at alone — a review is not conversation activity" do
    before = sessions.find("s").updated_at
    handler.call(command(session_id: "s", message: 0, flag: 0, status: "resolved"))
    expect(sessions.find("s").updated_at).to eq(before)
  end

  it "keeps the session's place in recent — an older session is not bumped to the top" do
    sessions.create(id: "newer")
    handler.call(command(session_id: "s", message: 0, flag: 0, status: "reported"))
    expect(sessions.recent(2).map(&:id)).to eq(%w[newer s])
  end

  it "refuses an unknown flag, a bad index and an unknown status" do
    expect { handler.call(command(session_id: "s", message: 0, flag: 3, status: "reported")) }.to raise_error(Insika::NotFoundError)
    expect { handler.call(command(session_id: "s", message: -1, flag: -1, status: "reported")) }.to raise_error(Insika::NotFoundError)
    expect { handler.call(command(session_id: "s", message: "x", flag: 0, status: "reported")) }.to raise_error(Insika::ValidationError)
    expect { handler.call(command(session_id: "s", message: 0, flag: 0, status: "maybe")) }.to raise_error(Insika::ValidationError)
  end
end
