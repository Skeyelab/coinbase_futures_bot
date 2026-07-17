# frozen_string_literal: true

module Sentiment
  # Parses the sentiment source/symbol registry so adding a feed or a tradable
  # symbol is a config edit (config/sentiment_sources.yml) rather than a code
  # change across the tagging, scoring, and aggregation layers.
  class SourceConfig
    DEFAULT_PATH = Rails.root.join("config", "sentiment_sources.yml")

    def self.default
      @default ||= new(YAML.safe_load_file(DEFAULT_PATH))
    end

    def initialize(data)
      @data = data || {}
    end

    def sources
      @data["sources"] || {}
    end

    def symbols
      @data["symbols"] || {}
    end

    # Word-boundary matcher per symbol, built from its configured keywords, for
    # tagging article text. Case-insensitive.
    def symbol_keywords
      symbols.filter_map do |symbol, cfg|
        words = Array(cfg["keywords"])
        next if words.empty?

        [symbol, /\b(#{words.map { |w| Regexp.escape(w) }.join("|")})\b/i]
      end.to_h
    end

    # RSS-backed sources, shaped for GenericRssClient construction.
    def rss_feeds
      sources.filter_map do |source_name, cfg|
        next unless cfg["client"] == "rss"

        {source_name: source_name, url: cfg["url"]}
      end
    end
  end
end
