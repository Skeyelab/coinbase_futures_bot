# frozen_string_literal: true

require "rails_helper"

# Issue #568: the maker-band strategy's edge claim rests entirely on fill
# honesty. In fill_model: :through_price a resting limit fills ONLY when the
# bar trades strictly THROUGH the price — a bar that merely touches the limit
# is assumed to be adverse-selection flow that never filled us. Maker fills
# (entry and TP) pay maker_fee_rate at the limit exactly, no slippage; the
# hard stop is still a taker exit with slippage and the taker fee.
RSpec.describe PaperTrading::ExchangeSimulator, "fill_model: :through_price" do
  def candle(close:, high:, low:)
    Struct.new(:close, :high, :low, :timestamp).new(close, high, low, Time.utc(2026, 1, 1))
  end

  def sim(maker_fee_rate: 0.0, fee_rate: 0.0003, slippage: 0.0002)
    described_class.new(starting_equity_usd: 10_000.0, fill_model: :through_price,
      maker_fee_rate: maker_fee_rate, fee_rate: fee_rate, slippage: slippage)
  end

  describe "entry fills" do
    it "does NOT fill a buy limit when the bar low merely touches the price" do
      s = sim
      id = s.place_limit(symbol: "X", side: :buy, price: 99.0, quantity: 1.0)
      s.on_candle(candle(close: 100.0, high: 101.0, low: 99.0))

      expect(s.orders[id].status).to eq(:open)
      expect(s.fills).to be_empty
    end

    it "fills a buy limit when the bar trades through it, at the limit exactly (no slippage)" do
      s = sim(slippage: 0.001)
      id = s.place_limit(symbol: "X", side: :buy, price: 99.0, quantity: 1.0)
      s.on_candle(candle(close: 100.0, high: 101.0, low: 98.9))

      expect(s.orders[id].status).to eq(:filled)
      expect(s.fills.last[:price]).to eq(99.0)
    end

    it "does NOT fill a sell limit when the bar high merely touches the price" do
      s = sim
      id = s.place_limit(symbol: "X", side: :sell, price: 101.0, quantity: 1.0)
      s.on_candle(candle(close: 100.0, high: 101.0, low: 99.0))

      expect(s.orders[id].status).to eq(:open)
    end

    it "fills a sell limit when the bar trades through it, at the limit exactly" do
      s = sim(slippage: 0.001)
      id = s.place_limit(symbol: "X", side: :sell, price: 101.0, quantity: 1.0)
      s.on_candle(candle(close: 100.0, high: 101.1, low: 99.0))

      expect(s.orders[id].status).to eq(:filled)
      expect(s.fills.last[:price]).to eq(101.0)
    end

    it "charges the maker fee rate on entry, not the taker rate" do
      s = sim(maker_fee_rate: 0.0001, fee_rate: 0.01)
      s.place_limit(symbol: "X", side: :buy, price: 100.0, quantity: 1.0)
      s.on_candle(candle(close: 101.0, high: 102.0, low: 99.9))

      expect(s.fills.last[:fee]).to be_within(1e-9).of(100.0 * 1.0 * 0.0001)
    end

    it "charges zero on entry at the promo 0% maker rate" do
      s = sim(maker_fee_rate: 0.0)
      s.place_limit(symbol: "X", side: :buy, price: 100.0, quantity: 1.0)
      s.on_candle(candle(close: 101.0, high: 102.0, low: 99.9))

      expect(s.fills.last[:fee]).to eq(0.0)
      expect(s.equity_usd).to eq(10_000.0)
    end
  end

  describe "TP exits (resting maker limit at the mean)" do
    def filled_long(s, tp:, sl:)
      id = s.place_limit(symbol: "X", side: :buy, price: 99.0, quantity: 1.0, tp: tp, sl: sl)
      s.on_candle(candle(close: 99.5, high: 99.6, low: 98.9))
      expect(s.orders[id].status).to eq(:filled)
      id
    end

    it "does NOT close when the bar merely touches the TP" do
      s = sim
      id = filled_long(s, tp: 100.0, sl: 95.0)
      s.on_candle(candle(close: 99.8, high: 100.0, low: 99.2))

      expect(s.orders[id].status).to eq(:filled)
    end

    it "closes at the TP exactly with the maker fee when the bar trades through it" do
      s = sim(maker_fee_rate: 0.0, fee_rate: 0.01, slippage: 0.001)
      id = filled_long(s, tp: 100.0, sl: 95.0)
      s.on_candle(candle(close: 100.2, high: 100.3, low: 99.5))

      expect(s.orders[id].status).to eq(:closed)
      expect(s.fills.last[:price]).to eq(100.0)
      expect(s.fills.last[:fee]).to eq(0.0)
      # +1.0 gross on 1 unit, zero fees both sides
      expect(s.equity_usd).to be_within(1e-9).of(10_001.0)
    end
  end

  describe "SL exits (hard stop, taker)" do
    it "stops out on a TOUCH — stops are not resting limits" do
      s = sim(fee_rate: 0.0003, slippage: 0.0)
      id = s.place_limit(symbol: "X", side: :buy, price: 99.0, quantity: 1.0, tp: 100.0, sl: 97.0)
      s.on_candle(candle(close: 99.5, high: 99.6, low: 98.9))
      s.on_candle(candle(close: 97.5, high: 99.0, low: 97.0))

      expect(s.orders[id].status).to eq(:closed)
      expect(s.fills.last[:fee]).to be_within(1e-9).of(97.0 * 0.0003)
    end

    it "applies adverse slippage to the stop fill" do
      s = sim(fee_rate: 0.0, slippage: 0.001)
      s.place_limit(symbol: "X", side: :buy, price: 99.0, quantity: 1.0, tp: 100.0, sl: 97.0)
      s.on_candle(candle(close: 99.5, high: 99.6, low: 98.9))
      s.on_candle(candle(close: 97.5, high: 99.0, low: 96.5))

      expect(s.fills.last[:price]).to be_within(1e-9).of(97.0 * (1 - 0.001))
    end

    it "takes the STOP when one bar triggers both TP and SL (pessimistic intrabar ordering)" do
      s = sim(fee_rate: 0.0, slippage: 0.0)
      id = s.place_limit(symbol: "X", side: :buy, price: 99.0, quantity: 1.0, tp: 100.0, sl: 97.0)
      s.on_candle(candle(close: 99.5, high: 99.6, low: 98.9))
      s.on_candle(candle(close: 99.0, high: 101.0, low: 96.0))

      expect(s.orders[id].status).to eq(:closed)
      expect(s.fills.last[:price]).to eq(97.0)
    end
  end

  describe "default :touch mode is unchanged" do
    it "still fills a buy limit at a touch" do
      s = described_class.new(starting_equity_usd: 10_000.0, fee_rate: 0.0, slippage: 0.0)
      id = s.place_limit(symbol: "X", side: :buy, price: 99.0, quantity: 1.0)
      s.on_candle(candle(close: 100.0, high: 101.0, low: 99.0))

      expect(s.orders[id].status).to eq(:filled)
    end
  end
end
