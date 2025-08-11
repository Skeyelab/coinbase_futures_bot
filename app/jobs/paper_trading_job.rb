# frozen_string_literal: true

class PaperTradingJob < ApplicationJob
  queue_as :default

  SYMBOL = "BTC-USD"

  def perform
    simulator = PaperTrading::ExchangeSimulator.new(starting_equity_usd: starting_equity_usd)
    strategy = Strategy::Pullback1h.new

    # Use last 300 candles for context and simulate one step forward
    candles = Candle.for_symbol(SYMBOL).hourly.order(:timestamp).last(300)
    return if candles.size < 200

    order = strategy.signal(candles: candles, symbol: SYMBOL, equity_usd: simulator.equity_usd)
    if order && order[:quantity].to_f > 0
      simulator.place_limit(symbol: SYMBOL, side: order[:side], price: order[:price], quantity: order[:quantity], tp: order[:tp], sl: order[:sl])
    end

    # Advance one candle to process fills and exits
    next_candle = next_hour_candle_stub(candles.last)
    simulator.on_candle(next_candle)

    Rails.logger.info("[Paper] equity_usd=#{simulator.equity_usd.round(2)} orders=#{simulator.orders.size} fills=#{simulator.fills.size}")
  end

  private

  def starting_equity_usd
    (ENV["PAPER_EQUITY_USD"] || 10_000).to_f
  end

  # Placeholder: in real paper mode, you would ingest live candles. Here we bump close slightly.
  def next_hour_candle_stub(last_candle)
    Candle.new(
      symbol: last_candle.symbol,
      timeframe: last_candle.timeframe,
      timestamp: last_candle.timestamp + 1.hour,
      open: last_candle.close,
      high: last_candle.close * 1.002,
      low: last_candle.close * 0.998,
      close: last_candle.close * 1.001,
      volume: last_candle.volume
    )
  end
end