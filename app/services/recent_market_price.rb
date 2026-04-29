# frozen_string_literal: true

class RecentMarketPrice
  STALE_AFTER = 5.minutes

  def self.for_product(product_id)
    recent_tick_price(product_id) || recent_one_minute_candle_price(product_id)
  end

  def self.recent_tick_price(product_id)
    Tick.where(product_id: product_id)
      .where("observed_at > ?", STALE_AFTER.ago)
      .order(observed_at: :desc)
      .pick(:price)
  end

  def self.recent_one_minute_candle_price(product_id)
    Candle.for_symbol(product_id)
      .one_minute
      .where("timestamp > ?", STALE_AFTER.ago)
      .order(timestamp: :desc)
      .pick(:close)
  end
end
