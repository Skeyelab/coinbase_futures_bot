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

    # Relative trust for a source when aggregating; unknown sources default to 1.0.
    def weight_for(source_name)
      (sources.dig(source_name, "weight") || 1.0).to_f
    end

    # Symbols a source is allowed to tag. nil means unscoped (tag any symbol).
    def symbols_for(source_name)
      scope = sources.dig(source_name, "symbols")
      scope.presence
    end

    # The symbol a source may tag WITHOUT a keyword match, or nil.
    #
    # `symbols:` is a scope — the most a source is ALLOWED to tag — not a claim
    # about what it publishes. investing_commodities_rss is scoped [OIL-USD] and
    # still runs gold, palladium, and wheat headlines; tagging those OIL-USD
    # would feed metals prices into oil's z-score baseline as if they were oil
    # sentiment. A miss loses signal, but a false tag adds noise that looks like
    # signal, which is worse.
    #
    # `exclusive: true` is therefore a separate, explicit assertion that every
    # item a feed publishes is about one symbol, set only on feeds verified
    # single-topic against their real recent output. It requires a scope of
    # exactly one symbol: on a multi-symbol source there is no way to pick which
    # symbol a keyword-less item belongs to, and tagging all of them
    # double-counts one article.
    def exclusive_symbol_for(source_name)
      return nil unless sources.dig(source_name, "exclusive")

      scope = symbols_for(source_name)
      (scope && scope.size == 1) ? scope.first : nil
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
