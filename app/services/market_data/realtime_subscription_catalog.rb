# frozen_string_literal: true

module MarketData
  class RealtimeSubscriptionCatalog
    KNOWN_SPOT_PRODUCT_IDS = %w[BTC-USD ETH-USD].freeze

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
