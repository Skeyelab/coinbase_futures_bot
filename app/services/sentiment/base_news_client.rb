# frozen_string_literal: true

module Sentiment
  # Base class for all news clients to ensure consistent interface
  class BaseNewsClient
    # Shared with the backfill task so both sides compute the identical digest.
    def self.normalized_hash_input(url, title, symbol = nil)
      [url, title, symbol].compact.map { |v| v.to_s.downcase.gsub(/\s+/, " ").strip }.join("|")
    end

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

    # Normalize a feed timestamp to UTC. Uses an explicit UTC zone rather than
    # Time.parse, which interprets a timezone-less string in the SERVER's local
    # zone — on a non-UTC machine that shifts every article hours away from real
    # time, so it never lands in AggregateSentimentJob's UTC windows and
    # sentiment silently reads empty. Explicit offsets in the string are honored.
    def parse_timestamp(timestamp_str)
      Time.find_zone("UTC").parse(timestamp_str.to_s)&.utc || Time.now.utc
    rescue
      Time.now.utc
    end

    # Common method to generate content hash. Include the symbol so an article
    # tagged with multiple symbols yields a distinct hash per symbol and both
    # rows survive the (source, raw_text_hash) upsert dedup.
    # Normalized before hashing. A feed that republishes the same story with
    # different capitalisation or re-wrapped whitespace produced a different
    # hash and therefore a second row — observed live:
    #
    #   "Galaxy, MARA Holdings deepen Texas expansion with land acquisitions"
    #   "Galaxy, MARA Holdings deepen Texas expansion with land Acquisitions"
    #
    # Both ingested. That inflates the inflow rate, which is precisely the
    # number used to decide whether sentiment is undersampled (#431) — so the
    # duplicate makes the feed look healthier than it is.
    #
    # Changing this changes every hash, so existing rows no longer match and
    # would all re-insert once. `rake sentiment:rehash` backfills them; run it
    # with the deploy.
    def generate_content_hash(url, title, symbol = nil)
      Digest::SHA256.hexdigest(self.class.normalized_hash_input(url, title, symbol))
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

      return symbols.uniq if symbols.any?

      # A source declared `exclusive: true` publishes only its one scoped symbol,
      # so a keyword miss there is a hole in the keyword list, not an off-topic
      # article. Measured on rigzone_rss: 23 of 76 ingested items carried no
      # OIL-USD keyword, and 20 of those 23 were plainly oil & gas industry news
      # ("Eni Greenlights Cyprus' First Hydrocarbon Project", "Matador Buys
      # Permian Assets", "Chevron Shuts Production in Preparation for Bertha").
      # Non-exclusive sources keep falling through to nil — see
      # SourceConfig#exclusive_symbol_for for why that distinction is deliberate.
      [config.exclusive_symbol_for(source_name)]
    end
  end
end
