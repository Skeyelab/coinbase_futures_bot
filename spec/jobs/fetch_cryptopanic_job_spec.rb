require "rails_helper"

RSpec.describe FetchCryptopanicJob, type: :job do
  it "upserts normalized events into SentimentEvent" do
    client = instance_double(Sentiment::CryptoPanicClient, enabled?: true)
    events = [
      {source: "cryptopanic", symbol: "BTC-USD", url: "u1", title: "t1", published_at: Time.now.utc,
       raw_text_hash: "h1", meta: {}},
      {source: "cryptopanic", symbol: "ETH-USD", url: "u2", title: "t2", published_at: Time.now.utc,
       raw_text_hash: "h2", meta: {}}
    ]
    allow(Sentiment::CryptoPanicClient).to receive(:new).and_return(client)
    allow(client).to receive(:fetch_recent).and_return(events)

    expect do
      described_class.perform_now(max_pages: 1)
    end.to change { SentimentEvent.count }.by(2)

    # Idempotent upsert on same payloads
    expect do
      described_class.perform_now(max_pages: 1)
    end.not_to(change { SentimentEvent.count })
  end
end
