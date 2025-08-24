require "rails_helper"

RSpec.describe "Sentiment endpoint", type: :request do
  it "returns latest aggregates as JSON" do
    t = Time.now.utc.change(sec: 0)
    SentimentAggregate.create!(symbol: "BTC-USD-PERP", window: "15m", window_end_at: t, count: 2, avg_score: 0.1, z_score: 1.2)

    get "/sentiment/aggregates", params: {symbol: "BTC-USD-PERP", window: "15m", limit: 1}
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["symbol"]).to eq("BTC-USD-PERP")
    expect(body["window"]).to eq("15m")
    expect(body["count"]).to eq(1)
    expect(body["data"]).to be_an(Array)
    expect(body["data"].first["z_score"]).to eq(1.2)
  end
end
