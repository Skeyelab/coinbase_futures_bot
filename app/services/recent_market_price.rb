# frozen_string_literal: true

class RecentMarketPrice
  STALE_AFTER = 5.minutes

  def self.for_product(product_id)
    recent_tick_price(product_id) || recent_one_minute_candle_price(product_id)
  end

  def self.recent_tick_price(product_id)
    recent_tick = Tick.where(product_id: product_id)
      .order(observed_at: :desc)
      .first

    return unless recent_tick && recent_tick.observed_at > STALE_AFTER.ago

    recent_tick.price
  end

  def self.recent_one_minute_candle_price(product_id)
    recent_candle = Candle.for_symbol(product_id)
      .one_minute
      .order(timestamp: :desc)
      .first

    return unless recent_candle && recent_candle.timestamp > STALE_AFTER.ago

    recent_candle.close
  end
end
