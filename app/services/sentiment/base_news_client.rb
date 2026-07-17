# frozen_string_literal: true

module Sentiment
  # Base class for all news clients to ensure consistent interface
  class BaseNewsClient
    include SentryServiceTracking

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Must be implemented by subclasses
    # Returns array of normalized event hashes
    def fetch_recent(max_pages: 2)
      raise NotImplementedError, "Subclasses must implement fetch_recent"
    end

    # Must be implemented by subclasses
    # Returns boolean indicating if the client is properly configured
    def enabled?
      raise NotImplementedError, "Subclasses must implement enabled?"
    end

    # Must be implemented by subclasses
    # Returns string identifier for this news source
    def source_name
      raise NotImplementedError, "Subclasses must implement source_name"
    end

    protected

    # Common method to normalize timestamps
    def parse_timestamp(timestamp_str)
      Time.parse(timestamp_str)
    rescue
      Time.now.utc
    end

    # Common method to generate content hash. Include the symbol so an article
    # tagged with multiple symbols yields a distinct hash per symbol and both
    # rows survive the (source, raw_text_hash) upsert dedup.
    def generate_content_hash(url, title, symbol = nil)
      Digest::SHA256.hexdigest([url, title, symbol].compact.join("|"))
    end

    # Common method to map currencies to trading symbols
    def map_currencies_to_symbols(codes)
      Array(codes).filter_map do |code|
        case code.upcase
        when "BTC", "BITCOIN" then "BTC-USD"
        when "ETH", "ETHEREUM" then "ETH-USD"
        end
      end.uniq
    end

    # Extract trading-symbol mentions from text. Tagging keywords come from
    # config/sentiment_sources.yml so a new symbol is a config edit. ("gas" is
    # intentionally not a crude keyword there — it false-positives on natural
    # gas and gasoline stories.) Results are restricted to the source's declared
    # symbol scope so an oil feed doesn't tag BTC off a passing mention.
    def extract_crypto_symbols(text)
      config = SourceConfig.default
      scope = config.symbols_for(source_name)

      symbols = config.symbol_keywords.filter_map do |symbol, pattern|
        next if scope && !scope.include?(symbol)

        symbol if pattern.match?(text)
      end

      symbols.empty? ? [nil] : symbols.uniq
    end
  end
end
