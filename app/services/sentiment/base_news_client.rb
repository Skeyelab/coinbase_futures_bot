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

    # Symbol tagging keywords. "gas" is deliberately excluded — it false-positives
    # heavily on natural gas and gasoline stories unrelated to crude.
    SYMBOL_KEYWORDS = {
      "BTC-USD" => /\b(BTC|BITCOIN)\b/,
      "ETH-USD" => /\b(ETH|ETHEREUM)\b/,
      "OIL-USD" => /\b(OIL|CRUDE|WTI|BRENT|OPEC|PETROLEUM|BARREL)\b/
    }.freeze

    # Extract trading-symbol mentions from text
    def extract_crypto_symbols(text)
      text_upper = text.upcase
      symbols = SYMBOL_KEYWORDS.filter_map { |symbol, pattern| symbol if text_upper.match?(pattern) }

      symbols.empty? ? [nil] : symbols.uniq
    end
  end
end
