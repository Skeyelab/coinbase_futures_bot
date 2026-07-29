# frozen_string_literal: true

module Trading
  # The fee schedule Coinbase is charging THIS account right now (issue #585).
  #
  # We hardcoded a ~3 bps perp taker rate as an ENV default and priced twelve
  # BIP backtests and ADR 0002's venue decision on it. The first real fills came
  # back at 10.175 bps. /transaction_summary would have answered 0.0008 on
  # request, the whole time.
  #
  # freqtrade's `fee` option is the model: it "should normally not be
  # configured, which has freqtrade fall back to the exchange default fee". A
  # hardcoded rate cannot silently diverge from the venue if there is no
  # hardcoded rate.
  #
  # Two things a constant structurally cannot express:
  #
  #   1. The tier is VOLUME-BASED and moves. This account paid 2.0 bps on BIP in
  #      Aug 2025 and 10.175 bps in Jul 2026 — same instrument, different
  #      30-day trailing band (currently Advanced 3, $10k-$50k).
  #   2. Maker is 0.00075. ADR 0002 claimed 0%, and the maker-optimization work
  #      (#374/#377) was justified on free maker fills.
  #
  # NOT a replacement for Trading::FeeTruth. This is the published schedule;
  # FeeTruth is what the venue actually charged, including the flat
  # $0.14/contract the schedule does not state. The schedule makes the model
  # right by default; FeeTruth keeps it honest.
  class VenueFeeSchedule
    STORE_KEY = "venue_fee_schedule"

    class << self
      # Fetches and persists. Returns the schedule hash, or nil when the venue
      # could not be reached or answered without rates.
      def fetch!(client: Trading::CoinbasePositions.new, logger: Rails.logger)
        parsed = parse(client.transaction_summary(product_type: "FUTURE"))
        unless parsed
          logger&.warn("[VenueFeeSchedule] no usable venue fee schedule in the response — " \
                       "keeping #{current ? "the last known schedule" : "the seeded constants"}")
          return nil
        end

        store(parsed)
        logger&.info("[VenueFeeSchedule] #{parsed[:tier]}: taker #{bps(parsed[:taker_rate])} bps, " \
                     "maker #{bps(parsed[:maker_rate])} bps")
        parsed
      rescue => e
        # A blip must not erase a real measurement. Stale beats absent, because
        # absent means falling back to a constant that has already been wrong.
        logger&.warn("[VenueFeeSchedule] could not refresh the venue fee schedule " \
                     "(#{e.class}: #{e.message}) — keeping the last known one")
        nil
      end

      # The last schedule the venue gave us, or nil if it never has.
      def current
        record = BotRuntimeStat.find_by(key: STORE_KEY)
        value = record&.value
        return nil unless value.is_a?(Hash)

        taker = value["taker_rate"].to_f
        maker = value["maker_rate"].to_f
        return nil unless taker.positive?

        {taker_rate: taker, maker_rate: maker, tier: value["tier"],
         fetched_at: value["fetched_at"]}
      end

      private

      # A response missing the rates is not a schedule of zero. Refusing it
      # leaves the previous answer standing.
      def parse(tier)
        return nil unless tier.is_a?(Hash)

        taker = tier["taker_fee_rate"].to_f
        return nil unless taker.positive?

        {taker_rate: taker, maker_rate: tier["maker_fee_rate"].to_f,
         tier: tier["pricing_tier"].presence}
      end

      def store(parsed)
        record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
        record.value = {
          "taker_rate" => parsed[:taker_rate], "maker_rate" => parsed[:maker_rate],
          "tier" => parsed[:tier], "fetched_at" => Time.current.utc.iso8601
        }
        record.recorded_at = Time.current.utc
        record.save!
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      def bps(rate) = (rate.to_f * 10_000).round(2)
    end
  end
end
