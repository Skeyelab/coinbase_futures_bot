# Chooses which Kalshi markets are worth sampling.
#
# Kalshi lists tens of thousands of auto-generated combination markets that
# never trade. Sampling those burns rate limit and produces a data set of
# flat lines. This picks the markets that actually have a two-sided book.
module Watchlist
  # Auto-generated multi-leg combination markets. They quote rarely, never
  # carry news, and swamp the listing endpoints.
  COMBO_PREFIX = "KXMVE"

  def self.select_from(markets, min_volume_24h:, limit: 100, max_spread_cents: 10)
    markets
      .map { |m| normalize(m) }
      .select { |m| tradeable?(m, min_volume_24h, max_spread_cents) }
      .sort_by { |m| -m[:volume_24h] }
      .first(limit)
  end

  def self.normalize(market)
    bid = market["yes_bid_dollars"].to_f * 100
    ask = market["yes_ask_dollars"].to_f * 100

    {
      ticker: market["ticker"],
      title: market["title"],
      bid_cents: bid,
      ask_cents: ask,
      spread_cents: ask - bid,
      volume_24h: market["volume_24h_fp"].to_f,
      bid_size: market["yes_bid_size_fp"].to_f
    }
  end

  def self.tradeable?(market, min_volume_24h, max_spread_cents)
    return false if market[:ticker].to_s.start_with?(COMBO_PREFIX)
    return false if market[:bid_cents] <= 0 || market[:ask_cents] <= 0
    return false if market[:spread_cents] > max_spread_cents
    return false if market[:volume_24h] < min_volume_24h

    true
  end
end
