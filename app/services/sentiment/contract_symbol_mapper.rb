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

    # The price series to measure a sentiment symbol's predictiveness against
    # (issue #436). Prefers the symbol's own continuous spot candles (BTC-USD /
    # ETH-USD); when none exist (OIL has no spot), falls back to the contract for
    # its underlying with the most candle history. nil when nothing maps.
    def self.price_symbol_for(sentiment_symbol, timeframe: "1h")
      symbol = sentiment_symbol.to_s.strip.upcase
      return symbol if Candle.where(symbol: symbol, timeframe: timeframe).exists?

      underlying = UNDERLYING_TO_SENTIMENT.key(symbol)
      return nil if underlying.blank?

      candidates = contract_symbols_for(underlying)
      return nil if candidates.empty?

      Candle.where(symbol: candidates, timeframe: timeframe)
        .group(:symbol).order(Arel.sql("COUNT(*) DESC")).limit(1).count.keys.first
    end

    # The contracts whose candles can stand in for an underlying's price
    # series.
    #
    # This used to match candles directly with "symbol LIKE 'NOL%'". Postgres
    # cannot use the (symbol, timeframe, timestamp) index for a prefix LIKE
    # under the default collation, so it seq-scanned all 3.2M candle rows --
    # 973ms per call, 1,163 calls a day -- to find four symbols. It was the
    # largest single consumer of the Sentry quota, and the crash it triggered
    # in the slow-query monitor was the third largest.
    #
    # Reading the contract list instead is a small indexed lookup, and it is
    # what the method always meant: the comment above says "the contract for
    # its underlying". Disabled contracts stay eligible, because expiry
    # disables rather than deletes them and their history is still valid price
    # data.
    def self.contract_symbols_for(underlying)
      Contract.where(base_currency: underlying).pluck(:product_id)
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
