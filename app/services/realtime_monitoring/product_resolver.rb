# frozen_string_literal: true

module RealtimeMonitoring
  module ProductResolver
    module_function

    def futures_product_ids(override: nil, explicit: [])
      ids = Array(override).compact
      return ids if ids.any?

      futures_from_explicit = explicit.select { MarketData::RealtimeSubscriptionCatalog.futures_contract?(_1) }
      return futures_from_explicit if futures_from_explicit.any?
      return MarketData::RealtimeSubscriptionCatalog.futures_product_ids if explicit.empty?

      []
    end

    def spot_product_ids(override: nil, explicit: [])
      ids = Array(override).compact
      return ids if ids.any?

      spot_from_explicit = explicit.reject { MarketData::RealtimeSubscriptionCatalog.futures_contract?(_1) }
      return spot_from_explicit if spot_from_explicit.any?
      return MarketData::RealtimeSubscriptionCatalog.spot_product_ids if explicit.empty?

      []
    end
  end
end
