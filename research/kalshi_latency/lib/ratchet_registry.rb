require_relative "temp_market"
require_relative "touch_market"

# Decides what a Kalshi market actually ratchets on.
#
# THE REASON THIS EXISTS: strike_type does not tell you. Both of these carry
# strike_type "less" and they mean opposite things:
#
#   KXHIGHNY-26AUG04-T81       cap=81      "80 or below"
#     -> the day's HIGH must stay at or under the cap. A rising max REFUTES it.
#
#   KXBTCMINMON-BTC-26AUG31    cap=60000   "Below $60,000"
#     -> the running MINIMUM ever went under it. A falling min CONFIRMS it.
#
# Dispatching on strike_type alone would read every one-touch backwards, which
# is the most expensive kind of wrong: it would report a live contract as
# refuted and propose selling it.
#
# So the series is the authority, and an unknown series returns nil rather than
# a guess. Adding a series is a deliberate act that requires reading its rules.
module RatchetRegistry
  # observable: what running extreme this series ratchets on.
  #   :daily_high_f      the local day's maximum temperature, whole degrees
  #   :window_min_usd    the running minimum price since issuance
  #   :window_max_usd    the running maximum price since issuance
  SERIES = {
    "KXHIGH" => {kind: :temperature, observable: :daily_high_f},
    "KXBTCMINMON" => {kind: :touch_below, observable: :window_min_usd},
    "KXBTCMAXY" => {kind: :touch_above, observable: :window_max_usd},
    "KXETHMINMON" => {kind: :touch_below, observable: :window_min_usd},
    "KXETHMAXY" => {kind: :touch_above, observable: :window_max_usd}
  }.freeze

  def self.entry_for(ticker)
    SERIES.find { |prefix, _| ticker.to_s.start_with?(prefix) }&.last
  end

  def self.observable_for(ticker)
    entry_for(ticker)&.fetch(:observable)
  end

  # nil for any series we have not read the rules of. Silence beats a guess.
  def self.build(row)
    ticker = row["ticker"].to_s
    entry = entry_for(ticker)
    return nil unless entry

    case entry[:kind]
    when :temperature then TempMarket.from_api(row)
    when :touch_below then touch(ticker, :below, row["cap_strike"])
    when :touch_above then touch(ticker, :above, row["floor_strike"])
    end
  end

  def self.touch(ticker, direction, threshold)
    return nil if threshold.nil?

    TouchMarket.new(ticker: ticker, direction: direction, threshold: threshold.to_f)
  end
end
