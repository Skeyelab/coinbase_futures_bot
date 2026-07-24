# frozen_string_literal: true

# Precomputes sentiment predictiveness (issue #436) so OperatorSnapshot#status
# can read it cheaply instead of scanning weeks of aggregates + candles inline.
# Runs hourly (predictiveness moves slowly), per enabled sentiment symbol across
# a few horizons, and stores the result in bot_runtime_stats.
class PredictivenessSnapshotJob < ApplicationJob
  KEY = "indicators:predictiveness"
  HORIZONS = [1, 4, 24].freeze
  HEADLINE_HORIZON = 4
  DEFAULT_DAYS = ENV.fetch("PREDICTIVENESS_WINDOW_DAYS", "30").to_i

  def perform(days: DEFAULT_DAYS, now: Time.current)
    from = now - days.days
    symbols = Sentiment::ContractSymbolMapper.sentiment_symbols_for_enabled_contracts
    entries = symbols.filter_map { |symbol| entry_for(symbol, from, now) }
    store!({"computed_at" => now.utc.iso8601, "symbols" => entries}, now)
  end

  private

  def entry_for(sentiment_symbol, from, to)
    price_symbol = Sentiment::ContractSymbolMapper.price_symbol_for(sentiment_symbol)
    return nil if price_symbol.blank?

    horizons = HORIZONS.to_h do |hours|
      result = Sentiment::PredictivenessStudy.new(
        sentiment_symbol: sentiment_symbol, price_symbol: price_symbol, horizon_hours: hours
      ).run(from: from, to: to)
      [hours.to_s, result.slice(:correlation, :hit_rate, :n, :signal_count).transform_keys(&:to_s)]
    end

    headline = horizons.fetch(HEADLINE_HORIZON.to_s)
    {
      "sentiment_symbol" => sentiment_symbol,
      "price_symbol" => price_symbol,
      "horizons" => horizons,
      "maturity" => Sentiment::PredictivenessMaturity.label(n: headline["n"], signal_count: headline["signal_count"])
    }
  end

  def store!(payload, now)
    record = BotRuntimeStat.find_or_initialize_by(key: KEY)
    record.value = payload
    record.recorded_at = now.utc
    record.save!
  end
end
