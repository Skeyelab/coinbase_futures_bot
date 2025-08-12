# frozen_string_literal: true

require "rails_helper"

RSpec.describe Candle, type: :model do
  let(:valid_candle) do
    Candle.new(
      symbol: "BTC-USD",
      timeframe: "1h",
      timestamp: Time.now.utc,
      open: 50000.0,
      high: 51000.0,
      low: 49000.0,
      close: 50500.0,
      volume: 100.5
    )
  end

  it "is valid with valid attributes" do
    expect(valid_candle).to be_valid
  end

  it "requires symbol" do
    valid_candle.symbol = nil
    expect(valid_candle).not_to be_valid
    expect(valid_candle.errors[:symbol]).to include("can't be blank")
  end

  it "requires timestamp" do
    valid_candle.timestamp = nil
    expect(valid_candle).not_to be_valid
    expect(valid_candle.errors[:timestamp]).to include("can't be blank")
  end

  it "validates timeframe inclusion" do
    %w[15m 1h 6h 1d].each do |tf|
      valid_candle.timeframe = tf
      expect(valid_candle).to be_valid, "#{tf} should be valid"
    end

    %w[30m 2h 12h invalid].each do |tf|
      valid_candle.timeframe = tf
      expect(valid_candle).not_to be_valid, "#{tf} should be invalid"
      expect(valid_candle.errors[:timeframe]).to include("is not included in the list")
    end
  end

  it "enforces uniqueness of timestamp scoped to symbol and timeframe" do
    valid_candle.save!

    duplicate = Candle.new(
      symbol: valid_candle.symbol,
      timeframe: valid_candle.timeframe,
      timestamp: valid_candle.timestamp,
      open: 60000.0,
      high: 61000.0,
      low: 59000.0,
      close: 60500.0,
      volume: 200.0
    )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:timestamp]).to include("has already been taken")
  end

  it "scopes by symbol" do
    valid_candle.save!

    Candle.create!(
      symbol: "ETH-USD",
      timeframe: "1h",
      timestamp: Time.now.utc,
      open: 3000.0,
      high: 3100.0,
      low: 2900.0,
      close: 3050.0,
      volume: 50.0
    )

    btc_candles = Candle.for_symbol("BTC-USD")
    expect(btc_candles.count).to eq(1)
    expect(btc_candles.first.symbol).to eq("BTC-USD")
  end

  it "scopes hourly" do
    valid_candle.save!

    Candle.create!(
      symbol: "BTC-USD",
      timeframe: "15m",
      timestamp: Time.now.utc,
      open: 50000.0,
      high: 51000.0,
      low: 49000.0,
      close: 50500.0,
      volume: 100.5
    )

    hourly_candles = Candle.hourly
    expect(hourly_candles.count).to eq(1)
    expect(hourly_candles.first.timeframe).to eq("1h")
  end

  it "scopes fifteen_minute" do
    valid_candle.save!

    Candle.create!(
      symbol: "BTC-USD",
      timeframe: "15m",
      timestamp: Time.now.utc,
      open: 50000.0,
      high: 51000.0,
      low: 49000.0,
      close: 50500.0,
      volume: 100.5
    )

    fifteen_min_candles = Candle.fifteen_minute
    expect(fifteen_min_candles.count).to eq(1)
    expect(fifteen_min_candles.first.timeframe).to eq("15m")
  end

  it "maintains decimal precision within tolerance" do
    valid_candle.open = 123456.7890123456
    valid_candle.high = 123456.7890123456
    valid_candle.low = 123456.7890123456
    valid_candle.close = 123456.7890123456
    valid_candle.volume = 123456789.123456789

    expect(valid_candle).to be_valid
    valid_candle.save!

    reloaded = Candle.find(valid_candle.id)
    expect(reloaded.open.to_f).to be_within(0.0001).of(123456.7890123456)
    expect(reloaded.high.to_f).to be_within(0.0001).of(123456.7890123456)
    expect(reloaded.low.to_f).to be_within(0.0001).of(123456.7890123456)
    expect(reloaded.close.to_f).to be_within(0.0001).of(123456.7890123456)
    expect(reloaded.volume.to_f).to be_within(0.0001).of(123456789.123456789)
  end
end
