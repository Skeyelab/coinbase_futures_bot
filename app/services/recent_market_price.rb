# frozen_string_literal: true

# The one place that answers "what is this contract worth right now, according
# to data we already hold". DB-only by design: a Tick newer than STALE_AFTER,
# else a 1m Candle newer than STALE_AFTER, else nothing. No REST call — a mark
# read must not be able to block on the venue.
#
# It also owns what to do when the feed is DARK, because that is a decision and
# it had grown three independent answers:
#
#   * Trading::PositionLifecycle#resolve_price and
#     Trading::DayTradingPositionManager#get_current_price_for_position were
#     byte-identical "recent price, else entry price, warn either way" blocks,
#     differing only in the wording of the log line.
#   * PositionReconcileService#resolve_close_price made the same fall-back and
#     additionally reported whether it had fallen back.
#
# All three decide what price a position is marked or closed at, so they are one
# decision wearing three names. #mark answers the price and the "is this real?"
# question together, so a caller cannot use the entry-price fallback while
# believing it holds a live mark — the failure the separate copies allowed.
class RecentMarketPrice
  STALE_AFTER = 5.minutes

  # A resolved mark. `live?` is false when the feed was dark and `price` is the
  # position's own entry price — the fallback, not an observation.
  Mark = Struct.new(:price, :live) do
    def live? = live
  end

  def self.for_product(product_id)
    recent_tick_price(product_id) || recent_one_minute_candle_price(product_id)
  end

  # The mark for a position: the recent price when the feed is live, the
  # position's entry price when it is dark. Never returns a nil `price` unless
  # the position itself has no entry price. Pass a logger to have the dark-feed
  # fallback recorded; silent by default.
  def self.mark(position, logger: nil)
    price = for_product(position.product_id)
    return Mark.new(price: price, live: true) if price

    logger&.warn("No recent price data for #{position.product_id}, using entry price")
    Mark.new(price: position.entry_price, live: false)
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
