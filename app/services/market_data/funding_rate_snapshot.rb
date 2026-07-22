# frozen_string_literal: true

module MarketData
  # Snapshots the funding rate the products API advertises for the NEXT funding
  # timestamp of every perpetual we can see (issue #391).
  #
  # Funding history is not reconstructible after the fact — the API exposes only
  # the upcoming funding timestamp, and candles carry none of it. Until this runs
  # on a schedule, every perp backtest silently models funding as free.
  #
  # Cost is one API read for all products; the same `list_products` call the
  # candle job already makes.
  class FundingRateSnapshot
    # CDE perps (BIP/XPP/SLP/ETP) report `contract_expiry_type: "EXPIRING"` with a
    # 2030 expiry and leave `perpetual_details` empty — their funding fields sit at
    # the top level of future_product_details. INTX perps populate both. Read the
    # top level first and fall back, so neither venue is silently skipped.
    def self.call(rest: CoinbaseRest.new)
      new(rest: rest).call
    end

    def initialize(rest: CoinbaseRest.new)
      @rest = rest
    end

    def call
      rows = @rest.list_products.filter_map { |product| build_row(product) }

      if rows.empty?
        Rails.logger.warn("[Funding] No funding-bearing products found; nothing snapshotted")
        return 0
      end

      FundingRate.upsert_all(
        rows,
        unique_by: :index_funding_rates_on_product_id_and_funding_time,
        update_only: [:funding_rate, :funding_interval_seconds, :open_interest, :observed_at]
      )

      Rails.logger.info("[Funding] Snapshotted #{rows.size} perp funding rates: #{rows.map { |r| r[:product_id] }.join(", ")}")
      rows.size
    end

    private

    def build_row(product)
      details = product["future_product_details"] || {}
      perpetual = details["perpetual_details"] || {}

      rate = presence_of(details["funding_rate"], perpetual["funding_rate"])
      funding_time = presence_of(details["funding_time"], perpetual["funding_time"])
      interval = parse_interval(details["funding_interval"])
      return nil if rate.nil? || funding_time.nil? || interval.nil?

      now = Time.now.utc
      {
        product_id: product["product_id"],
        funding_time: Time.parse(funding_time).utc,
        funding_rate: BigDecimal(rate),
        funding_interval_seconds: interval,
        open_interest: presence_of(details["open_interest"], perpetual["open_interest"]),
        observed_at: now,
        created_at: now,
        updated_at: now
      }
    rescue ArgumentError, TypeError => e
      Rails.logger.error("[Funding] Unparseable funding data for #{product["product_id"]}: #{e.message}")
      nil
    end

    def presence_of(*candidates)
      candidates.map { |c| c.to_s.strip }.find(&:present?)
    end

    # Advertised as a duration string, e.g. "3600s" for hourly funding.
    def parse_interval(raw)
      match = raw.to_s.match(/\A(\d+)s\z/)
      (match && match[1].to_i.positive?) ? match[1].to_i : nil
    end
  end
end
