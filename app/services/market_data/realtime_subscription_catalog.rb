# frozen_string_literal: true

module MarketData
  class RealtimeSubscriptionCatalog
    # Spot markets that actually exist on Coinbase and can back a futures
    # contract with a reference feed. Deliberately NOT derived from
    # Contract::PREFIX_TO_BASE_CURRENCY: that map says what we ingest, this says
    # what spot feeds are real. They diverge — OIL has no spot pair, so a
    # derived list would subscribe to a nonexistent OIL-USD.
    #
    # A contract whose underlying is missing here degrades silently to no spot
    # feed, so adding a perp (ADR 0002) means adding its underlying here too.
    KNOWN_SPOT_PRODUCT_IDS = %w[BTC-USD ETH-USD XRP-USD].freeze

    def self.futures_contract?(product_id)
      product_id.to_s.end_with?("-CDE")
    end

    def self.futures_product_ids(extra: [])
      from_contracts = Contract.enabled.pluck(:product_id)
      from_positions = Position.open.distinct.pluck(:product_id).select { |id| futures_contract?(id) }

      (from_contracts + from_positions + Array(extra)).compact.uniq
    end

    def self.spot_product_ids(extra: [])
      from_contracts = Contract.enabled.filter_map do |contract|
        asset = contract.underlying_asset.presence
        "#{asset}-USD" if asset
      end.uniq

      supported = (from_contracts + Array(extra)).uniq & KNOWN_SPOT_PRODUCT_IDS
      supported.reject { |product_id| futures_contract?(product_id) }
    end
  end
end
