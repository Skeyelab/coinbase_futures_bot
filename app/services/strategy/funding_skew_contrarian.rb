# frozen_string_literal: true

module Strategy
  # Funding-skew contrarian (issue #568, memo candidate A — the rank-3
  # highest-a-priori candidate), driven by the #569 basis proxy because the
  # CDE funding-history API is member-only: persistent positive premium means
  # crowded longs paying to stay long, so fade them — SHORT when the hourly
  # premium z-score exceeds +entry_z, LONG below -entry_z. Two small edges
  # stack: positioned against the crowded side, and (live) earning the
  # funding that side pays.
  #
  #   - the skew measure is the FundingProxy z-score: latest hourly
  #     perp-vs-spot premium against the mean/stddev of the prior `window`
  #     hours, so "extreme" is regime-relative, not an absolute rate
  #   - the z-reversion exit is expressed as a PRICE so the engine and
  #     protections handle it like any other tp: with spot held constant,
  #     premium reverting from z to exit_z moves the perp by
  #     (|z| - exit_z) * stddev — tp sits there. sl is a hard fractional
  #     stop beyond entry.
  #   - taker entries assumed: the trigger is an hourly state change, not a
  #     resting quote. This candidate PAYS the ~3 bps taker fee — surviving
  #     it is part of the test (contrast MakerBandReversion, whose whole
  #     edge is not paying it).
  #
  # Below-threshold skew or insufficient/flat premium history returns nil
  # with last_rejection set — flat beats guessing.
  class FundingSkewContrarian
    DEFAULTS = {
      entry_z: 2.0, # ~2-sigma tail of the premium regime — the memo's 1-3 triggers/week shape
      exit_z: 0.5, # revert-toward-zero exit; not 0 so the tp is reachable before full decay
      window: 168, # hours (7d): long enough to define a regime, short enough to roll with it
      stop: 0.01, # hard stop fraction beyond entry (memo: ~1%)
      spot_symbol: "BTC-USD", # the premium's spot leg
      contracts: 1, # fixed size; the $1k book trades 1-2 contracts, not a risk model
      contract_size_usd: 100.0 # engine reads this to convert contracts to base units
    }.freeze

    attr_reader :last_rejection

    def initialize(config = {})
      @config = DEFAULTS.merge(config)
    end

    def candle_source
      @candle_source ||= Signals::CandleSource::Database.new
    end

    # The proxy caches bucket closes across calls; swapping the source
    # (engine preload per walk-forward window) must reach it too.
    def candle_source=(source)
      @candle_source = source
      @proxy&.candle_source = source
    end

    # window + 1 premiums plus the in-progress hour, in 1m bars — what the
    # preloading source (issue #387) must hold for the proxy's cold read.
    def warmup_candles
      {one_minute: (@config[:window].to_i + 2) * 60}
    end

    def signal(symbol:, equity_usd: 10_000.0, as_of: nil)
      @last_rejection = nil
      as_of ||= Time.current

      stats = proxy_for(symbol).z_score(as_of: as_of)
      return reject(:insufficient_premium_history) if stats.nil?

      z = stats[:z]
      return reject(:skew_inside_band) if z.abs < @config[:entry_z].to_f

      quantity = @config[:contracts].to_i
      return reject(:zero_size) unless quantity.positive?

      price = stats[:perp_close]
      # Premium reversion from |z| to exit_z, in price terms with spot flat.
      reversion = (z.abs - @config[:exit_z].to_f) * stats[:stddev]
      side, tp, sl = if z.positive?
        [:short, price * (1.0 - reversion), price * (1.0 + @config[:stop].to_f)]
      else
        [:long, price * (1.0 + reversion), price * (1.0 - @config[:stop].to_f)]
      end

      {
        side: side,
        price: price,
        quantity: quantity,
        tp: tp,
        sl: sl,
        # entry_z ~2 maps to ~20; beyond 10 sigma there is nothing more to
        # learn from how crowded the crowd is.
        confidence: [z.abs * 10.0, 100.0].min.round(1)
      }
    end

    private

    def proxy_for(symbol)
      @proxy ||= Signals::FundingProxy.new(
        perp_symbol: symbol, spot_symbol: @config[:spot_symbol],
        window: @config[:window].to_i, candle_source: candle_source
      )
    end

    def reject(code)
      @last_rejection = code
      nil
    end
  end
end
