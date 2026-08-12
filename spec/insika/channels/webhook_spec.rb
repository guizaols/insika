# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Channels::Webhook do
  let(:http) { double("http") }
  subject(:webhook) { described_class.new("https://ops.example.com/alerts", http: http) }

  it "POSTs the payload as JSON and returns the status" do
    expect(http).to receive(:request).with(
      method: :post, url: "https://ops.example.com/alerts",
      headers: { "content-type" => "application/json" },
      body: JSON.generate({ "type" => "budget_warning", "agent" => "bia" })
    ).and_return(status: 200, body: "ok")

    status = webhook.deliver({ "type" => "budget_warning", "agent" => "bia" },
                             to: "https://ops.example.com/alerts", delivery_id: "d-1")
    expect(status).to eq(200)
  end

  it "a non-2xx status is returned as-is (the ChannelDelivery's bounded retry decides)" do
    expect(http).to receive(:request).and_return(status: 502, body: "bad gateway")
    expect(webhook.deliver({}, to: "x", delivery_id: "d-1")).to eq(502)
  end

  it "a transport failure becomes a DeliveryError (the retry records it)" do
    expect(http).to receive(:request).and_raise(Insika::Error, "connection refused")
    expect { webhook.deliver({}, to: "x", delivery_id: "d-1") }
      .to raise_error(Insika::DeliveryError, /connection refused/)
  end
end