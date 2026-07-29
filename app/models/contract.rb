# frozen_string_literal: true

class Contract < ApplicationRecord
  include SentryTrackable

  belongs_to :underlying, optional: true

  validates :product_id, presence: true, uniqueness: true

  # Coinbase product-ID prefix => the asset the contract actually tracks.
  # Dated contracts (BIT/ET/NOL) and CDE perps (BIP/XPP) share one product-ID
  # shape — `PREFIX-DDMMMYY-CDE` — so only the prefix distinguishes them, and
  # perps carry a 2030 dummy expiry rather than a real one.
  #
  # This map is the single source of truth for which products we ingest at all:
  # MarketData::CoinbaseRest#upsert_products builds its filter from these keys,
  # so adding a perp here starts candle collection for it. Enabling a symbol for
  # TRADING is a separate decision — see Trading::SymbolSuspension and ADR 0002's
  # no-evidence-inheritance rule: a new perp collects data while suspended until
  # it earns enablement on its own walk-forward.
  #
  # That separation is now enforced rather than described (ADR 0006). Adding a
  # key here grants DATA COLLECTION and nothing else: Trading::SymbolSuspension
  # fails closed, so a symbol with no recorded enablement cannot open a
  # position. Before ADR 0006 this comment was aspirational — the suspension
  # store started empty, so one line here put an instrument on the order path.
  #
  # The venue is recorded alongside the asset because it is a property of the
  # INSTRUMENT, and routing depends on it (issue #390, ADR 0004 condition 1).
  # CostModel.perp? answers the same question from "a FundingRate row exists",
  # which is a data-availability proxy: it says "not a perp" for a perp we have
  # not snapshotted yet. That is a safe default for pricing (it over-charges)
  # and an unsafe one for routing (it would send BTC to the dated contract on a
  # funding-collection outage). Routing reads the prefix; pricing keeps its own.
  PRODUCT_PREFIXES = {
    "BIT" => {base_currency: "BTC", venue: :dated},   # dated nano BTC
    "ET" => {base_currency: "ETH", venue: :dated},    # dated nano ETH
    "NOL" => {base_currency: "OIL", venue: :dated},   # dated nano oil
    "BIP" => {base_currency: "BTC", venue: :perp},    # BTC perp — ADR 0002 home instrument
    "XPP" => {base_currency: "XRP", venue: :perp},    # XRP perp — ADR 0002 designated second seat
    # PAXG perp — gold exposure via a PERP rather than the dated GOL contract.
    # Measured 2026-07-27: same $4k notional and 20x margin either way, but
    # 3 bps taker vs dated gold's 9, no monthly roll, 24/7, and a 2030 expiry.
    # Dated gold is the worst cost-to-volatility on the venue (~18% of a daily
    # move vs the perp's ~8%), because gold's 1h sigma is ~25 bps — half of BTC
    # — so a 9 bps dated fee eats a large share of the move it is trying to
    # capture. Ingesting only: PAU is blocked from trading until an operator
    # records an enablement for it, and earns that on its own walk-forward, per
    # ADR 0002 / 0004. Enforced by the fail-closed gate since ADR 0006.
    "PAU" => {base_currency: "PAXG", venue: :perp}
  }.freeze

  PREFIX_TO_BASE_CURRENCY = PRODUCT_PREFIXES.transform_values { |v| v[:base_currency] }.freeze

  PERP_PREFIXES = PRODUCT_PREFIXES.select { |_, v| v[:venue] == :perp }.keys.freeze
  DATED_PREFIXES = PRODUCT_PREFIXES.select { |_, v| v[:venue] == :dated }.keys.freeze

  # asset => the perp prefix that trades it ("BTC" => "BIP"), and the same for
  # dated. One asset, one contract family per venue.
  PERP_PREFIX_BY_ASSET = PRODUCT_PREFIXES.select { |_, v| v[:venue] == :perp }
    .to_h { |prefix, v| [v[:base_currency], prefix] }.freeze
  DATED_PREFIX_BY_ASSET = PRODUCT_PREFIXES.select { |_, v| v[:venue] == :dated }
    .to_h { |prefix, v| [v[:base_currency], prefix] }.freeze

  scope :enabled, -> { where(enabled: true) }
  scope :current_month, -> { where("expiration_date >= ? AND expiration_date <= ?", Date.current.beginning_of_month, Date.current.end_of_month) }
  scope :upcoming_month, -> { where("expiration_date >= ? AND expiration_date <= ?", Date.current.next_month.beginning_of_month, Date.current.next_month.end_of_month) }
  scope :not_expired, -> { where("expiration_date > ?", Date.current) }
  scope :active, -> { enabled.not_expired }
  scope :tradeable, -> { enabled.where("expiration_date > ?", Date.current + 1.day) }

  # Is this product itself something we can trade right now (issue #484)?
  #
  # Matters because month resolution is wrong for a perp: BIP carries a 2030
  # dummy expiry, so current_month_for_asset("BTC") skips it and returns the
  # DATED BIT contract instead. A BIP tick would then be evaluated on BIP's
  # price feed and executed on BIT — wrong instrument, mismatched feed.
  #
  # When the tick already names a tradeable contract there is nothing to
  # resolve, perp or dated. Falls through to month resolution otherwise, which
  # is what a spot tick (BTC-USD) needs and what keeps dated rollover working.
  def self.tradeable_product?(product_id)
    return false if product_id.blank?
    return false unless MarketData::RealtimeSubscriptionCatalog.futures_contract?(product_id)

    tradeable.exists?(product_id: product_id)
  end

  def self.parse_contract_info(product_id)
    return nil unless product_id

    match = product_id.match(/^([A-Z]+)-(\d{2}[A-Z]{3}\d{2})-([A-Z]+)$/)
    return nil unless match

    prefix, date_str, suffix = match.captures

    begin
      expiration_date = Date.strptime(date_str, "%d%b%y")
    rescue Date::Error
      return nil
    end

    # Unmapped prefixes fall back to the prefix itself. That is deliberately
    # lossy but visible: an unmapped perp would resolve underlying_asset to
    # e.g. "BIP" and silently get no spot reference feed, which is why
    # PREFIX_TO_BASE_CURRENCY gates ingestion in the first place.
    base_currency = PREFIX_TO_BASE_CURRENCY.fetch(prefix, prefix)

    {
      base_currency: base_currency,
      quote_currency: "USD",
      expiration_date: expiration_date,
      contract_type: suffix
    }
  end

  def self.parse_expiry_date(product_id)
    return nil unless product_id.is_a?(String)

    match = product_id.match(/^[A-Z]+-(\d{1,2}[A-Z]{3}\d{2})-[A-Z]+$/)
    return nil unless match

    date_str = (match[1].length == 6) ? "0#{match[1]}" : match[1]
    Date.strptime(date_str, "%d%b%y")
  rescue Date::Error
    nil
  end

  def self.days_until_expiry(product_id)
    expiry_date = parse_expiry_date(product_id)
    return nil unless expiry_date

    (expiry_date - Date.current).to_i
  end

  def self.parse_expiry_from_api(api_response)
    if api_response["expiration_time"]
      begin
        Time.parse(api_response["expiration_time"]).to_date
      rescue ArgumentError => e
        Rails.logger.warn("Failed to parse API expiration_time '#{api_response["expiration_time"]}': #{e.message}")
        parse_expiry_date(api_response["product_id"]) if api_response["product_id"]
      end
    elsif api_response["product_id"]
      parse_expiry_date(api_response["product_id"])
    end
  end

  def self.get_expiry_info(product_id, positions_service: nil)
    result = {
      product_id: product_id,
      parsed_date: parse_expiry_date(product_id),
      days_until_expiry: days_until_expiry(product_id),
      api_expiry_time: nil,
      api_days_until_expiry: nil
    }

    if positions_service
      begin
        response = positions_service.list_open_positions(product_id: product_id)
        if response.is_a?(Array) && response.any?
          pos = response.first
          if pos["expiration_time"]
            result[:api_expiry_time] = pos["expiration_time"]
            api_date = Time.parse(pos["expiration_time"]).to_date
            result[:api_days_until_expiry] = (api_date - Date.current).to_i
          end
        end
      rescue => e
        Rails.logger.warn("Failed to fetch API expiry info for #{product_id}: #{e.message}")
      end
    end

    result
  end

  def self.expiring_soon?(product_id, buffer_days = 2)
    days = days_until_expiry(product_id)
    return false unless days

    days <= buffer_days
  end

  def self.expired?(product_id) = expired_contract?(product_id)

  def self.expired_contract?(product_id)
    days = days_until_expiry(product_id)
    return false unless days

    days < 0
  end

  def self.find_expiring_positions(buffer_days = 2)
    Position.open.select { |p| expiring_soon?(p.product_id, buffer_days) }
  end

  def self.find_expired_positions
    Position.open.select { |p| expired_contract?(p.product_id) }
  end

  MARGIN_TIERS = [
    [0..1, 2.0, "Expiry within 24 hours - double margin"],
    [2..3, 1.5, "Expiry within 3 days - 50% higher margin"],
    [4..7, 1.2, "Expiry within 1 week - 20% higher margin"]
  ].freeze

  def self.margin_impact_near_expiry(product_id)
    days = days_until_expiry(product_id)
    return nil unless days

    tier = MARGIN_TIERS.find { |range, _, _| range.cover?(days) }
    tier ? {multiplier: tier[1], reason: tier[2]} : {multiplier: 1.0, reason: "Normal margin requirements"}
  end

  def self.format_expiry_summary(positions)
    return "No positions to summarize" if positions.empty?

    positions.group_by { |p| days_until_expiry(p.product_id) }.map do |days, pos_list|
      count = pos_list.size
      products = pos_list.map(&:product_id).uniq.join(", ")

      case days
      when nil then "#{count} positions with unknown expiry: #{products}"
      when 0 then "#{count} positions expiring TODAY: #{products}"
      when 1 then "#{count} positions expiring TOMORROW: #{products}"
      else "#{count} positions expiring in #{days} days: #{products}"
      end
    end.join("\n")
  end

  def expired?
    expiration_date && expiration_date < Date.current
  end

  def current_month?
    return false unless expiration_date

    (Date.current.beginning_of_month..Date.current.end_of_month).cover?(expiration_date)
  end

  def upcoming_month?
    return false unless expiration_date

    (Date.current.next_month.beginning_of_month..Date.current.next_month.end_of_month).cover?(expiration_date)
  end

  def tradeable?
    return false unless expiration_date

    expiration_date > Date.current + 1.day
  end

  def underlying_asset
    contract_info = self.class.parse_contract_info(product_id)
    contract_info&.dig(:base_currency) || base_currency
  end

  def self.current_month_for_asset(asset)
    enabled.current_month.where(base_currency: asset).order(:expiration_date)
  end

  def self.upcoming_month_for_asset(asset)
    enabled.upcoming_month.where(base_currency: asset).order(:expiration_date)
  end

  # The product-ID prefix of a contract ("BIP-20DEC30-CDE" => "BIP").
  def self.prefix_for(product_id)
    product_id.to_s.split("-").first.presence
  end

  # Which asset does this product trade? Reverse of the prefix map, and the one
  # answer for both venues: BIT and BIP both mean BTC. Spot product ids
  # ("BTC-USD") answer themselves.
  def self.asset_for_product(product_id)
    prefix = prefix_for(product_id)
    return nil unless prefix

    PREFIX_TO_BASE_CURRENCY[prefix]
  end

  def self.perp_product?(product_id)
    PERP_PREFIXES.include?(prefix_for(product_id))
  end

  def self.dated_product?(product_id)
    DATED_PREFIXES.include?(prefix_for(product_id))
  end

  # Does a perpetual exist ON THE VENUE for this asset? A property of the
  # instrument catalogue, not of our database: it stays true when the row is
  # missing, which is exactly when the answer matters.
  def self.perp_prefix_for_asset(asset)
    PERP_PREFIX_BY_ASSET[asset.to_s.upcase]
  end

  def self.dated_prefix_for_asset(asset)
    DATED_PREFIX_BY_ASSET[asset.to_s.upcase]
  end

  # Tradeable perp rows for an asset. No month window: a perp does not roll, and
  # BIP's 2030 dummy expiry is in neither the current nor the upcoming month.
  def self.perp_for_asset(asset)
    prefix = perp_prefix_for_asset(asset)
    return none unless prefix

    tradeable.where(base_currency: asset.to_s.upcase)
      .where("product_id LIKE ?", "#{prefix}-%")
      .order(:expiration_date)
  end

  # Which contract does an ASSET trade right now?
  #
  # Prefer the perp; fall back to the dated current/upcoming month only where no
  # perp exists for the underlying. That is ADR 0002 (perps primary) plus ADR
  # 0004 (dated permitted where no perp exists) expressed as a rule rather than
  # a hardcoded prefix, so BTC follows BIP, OIL keeps following the front-month
  # NOL, and nothing else moves.
  #
  # Month-window selection cannot express this: both windows filter
  # expiration_date to a calendar month, and BIP expires 2030-12-20, so it is in
  # neither window on any date. Month resolution is dated-contract logic.
  #
  # When the asset HAS a perp but no tradeable row for it, this returns nil and
  # says so loudly rather than falling back to the dated contract. ADR 0004
  # condition 1 leaves no discretion — "BTC trades BIP, not BIT" — and a silent
  # reroute would put real money on a different instrument at a different fee
  # schedule than the one the strategy was gated on. A dropped signal is
  # recoverable; a fill on the wrong contract is not.
  def self.best_available_for_asset(asset, logger: Rails.logger)
    perp = perp_for_asset(asset).first
    return perp if perp

    if (perp_prefix = perp_prefix_for_asset(asset))
      logger.error("[Contract] #{asset} trades the #{perp_prefix} perp (ADR 0002/0004) but no tradeable " \
                   "#{perp_prefix} contract is available — refusing to route #{asset} to a dated contract")
      return nil
    end

    current_month_contracts = current_month_for_asset(asset).tradeable
    return current_month_contracts.first if current_month_contracts.any?

    upcoming_month_for_asset(asset).tradeable.first
  end
end
