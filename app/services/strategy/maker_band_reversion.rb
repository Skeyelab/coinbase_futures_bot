# frozen_string_literal: true

module Strategy
  # Maker-only volatility-band mean reversion (issue #568, memo candidate B).
  #
  # The claimed edge is NOT the signal — short-horizon BTC mean reversion is a
  # commodity effect that is negative after taker costs — it is the venue's
  # 0% maker rate, which lets a resting limit trade a signal that is
  # uneconomic for taker flow. Everything here follows from that:
  #
  #   - band: band_k x sigma around an EMA anchor of 5m closes, where sigma is
  #     the sample stddev of 5m simple returns over vol_period bars, scaled to
  #     price by the anchor
  #   - one resting limit per evaluation, on whichever band the last close is
  #     nearer to: LONG at anchor - k*sigma, SHORT at anchor + k*sigma
  #   - TP at the anchor (mean touch), also a resting maker limit
  #   - hard stop stop_m x sigma beyond the entry limit — the only taker leg
  #   - a quote that would cross the market is REFUSED (:not_passive): in a
  #     trend the anchor lags price until the near band sits on the wrong side
  #     of the close, and resting there would execute as taker flow. This is
  #     the documented trend failure mode — the strategy goes flat rather than
  #     chase. The other trend mode: constant-slope moves have zero return
  #     variance, so the band collapses below min_band_bps and nothing quotes.
  #
  # Fill honesty lives in the backtest (Engine/ExchangeSimulator
  # fill_model: :through_price), not here: a resting limit only counts as
  # filled when a bar trades strictly THROUGH it.
  class MakerBandReversion
    DEFAULTS = {
      anchor_period: 20, # EMA of 5m closes — the mean the band brackets
      vol_period: 20, # sample stddev of 5m simple returns
      band_k: 2.0, # band half-width in sigma
      stop_m: 2.0, # stop distance beyond the entry limit, in sigma
      min_band_bps: 5.0, # narrower than this cannot clear stop costs — stand down
      contracts: 1, # fixed size; the $1k book trades 1-2 contracts, not a risk model
      contract_size_usd: 100.0 # engine reads this to convert contracts to base units
    }.freeze

    attr_reader :last_rejection
    attr_writer :candle_source

    def initialize(config = {})
      @config = DEFAULTS.merge(config)
    end

    def candle_source
      @candle_source ||= Signals::CandleSource::Database.new
    end

    # Closes needed before anything can be quoted: the anchor EMA and
    # vol_period returns (vol_period + 1 closes), whichever is larger.
    def warmup_bars
      [@config[:anchor_period], @config[:vol_period] + 1].max
    end

    # Only 5m — declaring unused timeframes would make the preloading source
    # (issue #387) load candles nothing reads.
    def warmup_candles
      {five_minute: warmup_bars}
    end

    def signal(symbol:, equity_usd: 10_000.0, as_of: nil)
      @last_rejection = nil
      candles = candle_source.recent(symbol: symbol, timeframe: :five_minute,
        limit: warmup_bars, as_of: as_of)
      return reject(:insufficient_5m_candles) if candles.size < warmup_bars

      closes = candles.map { |c| c.close.to_f }
      anchor = Signals::Indicators.ema(closes, @config[:anchor_period])
      return reject(:indicators_unavailable) unless anchor&.positive?

      returns = closes.last(@config[:vol_period] + 1).each_cons(2).map { |a, b| b / a - 1.0 }
      sigma = Signals::Indicators.stddev(returns, @config[:vol_period])
      return reject(:indicators_unavailable) if sigma.nil?

      sigma_price = sigma * anchor
      band = @config[:band_k].to_f * sigma_price
      return reject(:band_too_narrow) if band / anchor * 10_000.0 < @config[:min_band_bps].to_f

      quantity = @config[:contracts].to_i
      return reject(:zero_size) unless quantity.positive?

      close = closes.last
      side, price, sl = if close >= anchor
        [:short, anchor + band, anchor + band + @config[:stop_m].to_f * sigma_price]
      else
        [:long, anchor - band, anchor - band - @config[:stop_m].to_f * sigma_price]
      end
      # Maker-only: a short limit at/below the market or a long limit at/above
      # it would cross and execute as taker flow, which this strategy cannot
      # price. Flat beats mismodeled.
      return reject(:not_passive) if (side == :short) ? price <= close : price >= close

      {
        side: side,
        price: price,
        quantity: quantity,
        tp: anchor,
        sl: sl,
        # Wider bands clear the (stop-side) cost bar with more room; beyond
        # ~100 bps of half-width there is nothing more to learn from width.
        confidence: [band / anchor * 10_000.0, 100.0].min.round(1)
      }
    end

    private

    def reject(code)
      @last_rejection = code
      nil
    end
  end
end
