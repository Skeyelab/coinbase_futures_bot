# frozen_string_literal: true

module Sentiment
  class ContractSymbolMapper
    UNDERLYING_TO_SENTIMENT = {
      "BTC" => "BTC-USD",
      "ETH" => "ETH-USD",
      "OIL" => "OIL-USD"
    }.freeze

    PREFIX_TO_UNDERLYING = {
      "BIT" => "BTC",
      "ET" => "ETH",
      "NOL" => "OIL"
    }.freeze

    def self.sentiment_symbol_for(product_id_or_underlying)
      return nil if product_id_or_underlying.blank?

      value = product_id_or_underlying.to_s.strip.upcase
      return value if UNDERLYING_TO_SENTIMENT.value?(value)

      underlying = underlying_from_product_id(value) || underlying_from_asset(value)
      UNDERLYING_TO_SENTIMENT[underlying]
    end

    def self.sentiment_symbols_for_enabled_contracts
      Contract.enabled.filter_map { |contract| sentiment_symbol_for(contract.product_id) }.uniq.sort
    end

    def self.underlying_from_product_id(product_id)
      prefix = product_id.match(/\A([A-Z]+)-/)&.captures&.first
      PREFIX_TO_UNDERLYING[prefix] || Contract.parse_contract_info(product_id)&.dig(:base_currency)
    end

    def self.underlying_from_asset(asset)
      normalized = asset.to_s.upcase
      return normalized if UNDERLYING_TO_SENTIMENT.key?(normalized)

      nil
    end

    private_class_method :underlying_from_product_id, :underlying_from_asset
  end
end
