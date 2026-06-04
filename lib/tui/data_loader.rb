# frozen_string_literal: true

module Tui
  class DataLoader
    def self.load
      latest_tick_at = Tick.maximum(:observed_at)
      live_prices = latest_prices_by_product
      futures_live_prices, spot_live_prices = split_live_prices(live_prices)
      last_eval_at = Rails.cache.read("real_time_signal_job.last_eval_at") || SignalAlert.maximum(:alert_timestamp)

      {
        day_pos_count: Position.open.day_trading.count,
        swing_pos_count: Position.open.swing_trading.count,
        signal_count: SignalAlert.active.count,
        positions: Position.open.order(entry_time: :desc).limit(50).to_a,
        signals: SignalAlert.active.recent.order(alert_timestamp: :desc).limit(25).to_a,
        latest_tick_at: latest_tick_at,
        last_eval_at: last_eval_at,
        live_prices: live_prices,
        futures_live_prices: futures_live_prices,
        spot_live_prices: spot_live_prices,
        halt_active: TradingHalt.halted?,
        refreshed_at: Time.now
      }
    end

    def self.latest_prices_by_product
      recent_ticks = Tick.where("observed_at > ?", 10.minutes.ago)
        .order(observed_at: :desc).limit(500).to_a
      recent_ticks.each_with_object({}) do |tick, memo|
        memo[tick.product_id] ||= tick
      end
    end

    def self.split_live_prices(live_prices)
      futures = live_prices.values.select { |t| t.product_id.match?(/CDE$/i) }
      spot = live_prices.values.reject { |t| t.product_id.match?(/CDE$/i) }
      [futures, spot]
    end
  end
end
