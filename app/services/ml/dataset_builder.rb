# frozen_string_literal: true

module Ml
  # Joins persisted path-dependent labels (issue #302 step 1) to extracted
  # features (step 2) into one pooled, time-ordered dataset. Target encoding:
  # win = 1, everything else = 0 — a label that resolved as a loss and one
  # the horizon never resolved are both "this was not a winnable entry", which
  # is the question the scorer must answer.
  #
  # A labeled bar without features (insufficient history) is dropped, never
  # padded; a feature row without a label contributes nothing.
  class DatasetBuilder
    attr_reader :symbols, :direction, :timeframe, :tp_frac, :sl_frac, :horizon

    def initialize(symbols:, direction:, tp_frac:, sl_frac:, horizon:, timeframe: "5m", extractor_config: {})
      raise ArgumentError, "direction must be long or short" unless PathDependentLabel::DIRECTIONS.include?(direction)

      @symbols = symbols
      @direction = direction
      @timeframe = timeframe
      @tp_frac = tp_frac
      @sl_frac = sl_frac
      @horizon = horizon
      @extractor_config = extractor_config
    end

    # Returns [{symbol:, timestamp:, features: {name => Float}, y: 0|1}, ...]
    # sorted by (timestamp, symbol) so downstream time-splitting is stable.
    def rows(from:, to:)
      rows = symbols.flat_map { |symbol| rows_for_symbol(symbol, from, to) }
      rows.sort_by! { |row| [row[:timestamp].to_i, row[:symbol]] }
      rows
    end

    private

    def rows_for_symbol(symbol, from, to)
      labels = PathDependentLabel
        .where(symbol: symbol, timeframe: timeframe, direction: direction)
        .for_shape(tp_frac: tp_frac, sl_frac: sl_frac, horizon: horizon)
        .where(bar_timestamp: from..to)
        .pluck(:bar_timestamp, :label)
      return [] if labels.empty?

      features = FeatureExtractor.new(symbol: symbol, config: @extractor_config)
        .features_for_range(from: from, to: to)
        .transform_keys(&:to_i)

      labels.filter_map do |bar_timestamp, label|
        row = features[bar_timestamp.to_i]
        next unless row

        {symbol: symbol, timestamp: bar_timestamp, features: row,
         y: (label == "win") ? 1 : 0}
      end
    end
  end
end
