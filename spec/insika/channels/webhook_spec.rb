# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Channels::Webhook do
  let(:http) { double("http") }
  subject(:webhook) { described_class.new("https://8.8.8.8/alerts", http: http) }

  it "POSTs the payload as JSON and returns the status" do
    expect(http).to receive(:request).with(
      method: :post, url: "https://8.8.8.8/alerts",
      headers: { "content-type" => "application/json" },
      body: JSON.generate({ "type" => "budget_warning", "agent" => "bia" })
    ).and_return(status: 200, body: "ok")

    status = webhook.deliver({ "type" => "budget_warning", "agent" => "bia" },
                             to: "https://8.8.8.8/alerts", delivery_id: "d-1")
    expect(status).to eq(200)
  end

  it "a non-2xx status is returned as-is (the ChannelDelivery's bounded retry decides)" do
    expect(http).to receive(:request).and_return(status: 502, body: "bad gateway")
    expect(webhook.deliver({}, to: "https://8.8.8.8/alerts", delivery_id: "d-1")).to eq(502)
  end

  it "a transport failure becomes a DeliveryError (the retry records it)" do
    expect(http).to receive(:request).and_raise(Insika::Error, "connection refused")
    expect { webhook.deliver({}, to: "https://8.8.8.8/alerts", delivery_id: "d-1") }
      .to raise_error(Insika::DeliveryError, /connection refused/)
  end

  describe "the egress guard (SSRF — WS6)" do
    # On the SAME strict defaults as the data-tool guard: https-only, private
    # and metadata destinations blocked — the `alerts.webhook` URL is operator
    # config, and without this a URL pointed at the inside of the boundary
    # exfiltrates alert events out of it.
    it "blocks a plain-http target by default (fails closed)" do
      expect { webhook.deliver({}, to: "http://8.8.8.8/alerts", delivery_id: "d-1") }
        .to raise_error(Insika::DeliveryError, /egress blocked/)
    end

    it "blocks a cloud-metadata / loopback / private target (SSRF)" do
      %w[
        https://169.254.169.254/latest/meta-data
        https://127.0.0.1/admin
        https://10.0.0.8/internal/alerts
      ].each do |url|
        expect { webhook.deliver({}, to: url, delivery_id: "d-1") }
          .to raise_error(Insika::DeliveryError, /egress blocked/)
      end
    end

    it "a non-URL is a DeliveryError, never a request" do
      expect(http).not_to receive(:request)
      expect { webhook.deliver({}, to: "not a url", delivery_id: "d-1") }
        .to raise_error(Insika::DeliveryError, /egress blocked/)
    end

    it "the guard runs on EVERY delivery (a host that turned private is caught)" do
      # first delivery is fine; the second hits a target that now sits on a
      # private range -> blocked before the request, not after the leak.
      expect(http).to receive(:request).with(
        hash_including(url: "https://8.8.8.8/alerts")
      ).and_return(status: 200, body: "ok")

      expect(webhook.deliver({}, to: "https://8.8.8.8/alerts", delivery_id: "d-1")).to eq(200)
      expect { webhook.deliver({}, to: "http://127.0.0.1:3000/alerts", delivery_id: "d-2") }
        .to raise_error(Insika::DeliveryError, /egress blocked/)
    end
  end
end
