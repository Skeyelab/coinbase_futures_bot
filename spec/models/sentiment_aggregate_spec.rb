require "rails_helper"

RSpec.describe SentimentAggregate, type: :model do
  it "validates presence and uniqueness on symbol/window/window_end_at" do
    t = Time.now.utc.change(sec: 0)
    described_class.create!(symbol: "BTC-USD-PERP", window: "15m", window_end_at: t)
    dup = described_class.new(symbol: "BTC-USD-PERP", window: "15m", window_end_at: t)
    expect(dup.valid?).to be(false)
    expect(dup.errors[:symbol]).to be_present

    other = described_class.new(symbol: "ETH-USD-PERP", window: "15m", window_end_at: t)
    expect(other.valid?).to be(true)
  end

  it "scopes by symbol and window" do
    t = Time.now.utc.change(sec: 0)
    a1 = described_class.create!(symbol: "BTC-USD-PERP", window: "15m", window_end_at: t)
    a2 = described_class.create!(symbol: "ETH-USD-PERP", window: "1h", window_end_at: t)

    expect(described_class.for_symbol("BTC-USD-PERP")).to include(a1)
    expect(described_class.for_symbol("BTC-USD-PERP")).not_to include(a2)

    expect(described_class.for_window("1h")).to include(a2)
    expect(described_class.for_window("1h")).not_to include(a1)
  end
end
