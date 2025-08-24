# frozen_string_literal: true

class CalibrationJob < ApplicationJob
  queue_as :default

  def perform
    TradingPair.enabled.find_each do |pair|
      calibrate_pair(pair)
    end
  end

  private

  def calibrate_pair(pair)
    candles = Candle.for_symbol(pair.product_id).hourly.where("timestamp >= ?", 120.days.ago).order(:timestamp).to_a
    return if candles.size < 300

    best = grid_search(candles)
    Rails.logger.info("[Calibrate] #{pair.product_id} best params: #{best.inspect}")
    # TODO: persist to settings store per symbol
  end

  def grid_search(candles)
    tp_targets = [0.004, 0.006, 0.008]
    sl_targets = [0.003, 0.004, 0.005]

    best = nil
    tp_targets.product(sl_targets).each do |tp, sl|
      pnl = simulate(candles, tp_target: tp, sl_target: sl)
      score = pnl
      best = {tp_target: tp, sl_target: sl, pnl: pnl} if best.nil? || score > best[:pnl]
    end
    best
  end

  def simulate(candles, tp_target:, sl_target:)
    sim = PaperTrading::ExchangeSimulator.new
    strat = Strategy::Pullback1h.new(tp_target: tp_target, sl_target: sl_target)

    candles.each_cons(300) do |window|
      order = strat.signal(candles: window, symbol: window.last.symbol, equity_usd: sim.equity_usd)
      if order && order[:quantity].to_f > 0
        sim.place_limit(symbol: window.last.symbol, side: order[:side], price: order[:price], quantity: order[:quantity], tp: order[:tp], sl: order[:sl])
      end
      sim.on_candle(window.last)
    end

    sim.equity_usd
  end
end
