# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketDataSubscribeJob, type: :job do
  it "starts subscriber with product ids" do
    fake = instance_double("Subscriber")
    allow(fake).to receive(:start)

    expect(MarketData::CoinbaseFuturesSubscriber).to receive(:new).with(hash_including(product_ids: [ "BTC-USD-PERP" ])) { fake }

    perform_enqueued_jobs do
      described_class.perform_now([ "BTC-USD-PERP" ])
    end

    expect(fake).to have_received(:start)
  end
end
