# frozen_string_literal: true

# Path-dependent (highlow2) labels — issue #302 step 1.
#
#   bin/rails "labels:generate[BIP-20DEC30-CDE,2025-08-01,2026-07-01]"
#   bin/rails "labels:reachability[BIP-20DEC30-CDE]"
#
# Shape defaults to the measured #497 200/120 (tp 0.020 / sl 0.012) at a
# 288-bar (24h of 5m) horizon; override with TP_FRAC / SL_FRAC / HORIZON /
# TIMEFRAME. Symbols are used as-is against stored candles.
namespace :labels do
  desc "Generate path-dependent labels for a symbol's candle history; prints JSON summary"
  task :generate, %i[symbol from to] => :environment do |_t, args|
    symbol = args[:symbol] || ENV.fetch("SYMBOL")
    from = Time.zone.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.zone.parse(args[:to] || ENV.fetch("TO"))

    generator = Labels::PathDependent.new(symbol: symbol, **labels_shape_from_env)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = generator.generate(from: from, to: to)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    puts JSON.pretty_generate(result.merge(
      symbol: symbol, timeframe: generator.timeframe,
      tp_frac: generator.tp_frac, sl_frac: generator.sl_frac,
      horizon: generator.horizon, elapsed_seconds: elapsed.round(2)
    ))
  end

  desc "Reachability report: share of bars where the tp/sl race is winnable, per direction"
  task :reachability, %i[symbol from to] => :environment do |_t, args|
    from = (args[:from] || ENV["FROM"]).presence&.then { |v| Time.zone.parse(v) }
    to = (args[:to] || ENV["TO"]).presence&.then { |v| Time.zone.parse(v) }
    shape = labels_shape_from_env
    tp_frac = shape[:tp_frac] || Labels::PathDependent::DEFAULT_TP_FRAC
    sl_frac = shape[:sl_frac] || Labels::PathDependent::DEFAULT_SL_FRAC
    horizon = shape[:horizon] || Labels::PathDependent::DEFAULT_HORIZON
    timeframe = shape[:timeframe] || Labels::PathDependent::DEFAULT_TIMEFRAME

    symbols = (args[:symbol] || ENV["SYMBOL"]).presence&.then { |s| [s] } ||
      PathDependentLabel.distinct.order(:symbol).pluck(:symbol)
    abort("no labels found — run labels:generate first") if symbols.empty?

    report = symbols.to_h do |symbol|
      [symbol, Labels::Reachability.report(symbol: symbol, timeframe: timeframe,
        tp_frac: tp_frac, sl_frac: sl_frac, horizon: horizon, from: from, to: to)]
    end

    # effective_n is the honest sample size: overlapping label windows make
    # raw n wildly optimistic (~horizon-fold). Both are printed on purpose.
    puts JSON.pretty_generate({
      tp_frac: tp_frac.to_f, sl_frac: sl_frac.to_f, horizon: horizon,
      timeframe: timeframe, symbols: report
    })
  end
end

def labels_shape_from_env
  {
    tp_frac: ENV["TP_FRAC"]&.to_f,
    sl_frac: ENV["SL_FRAC"]&.to_f,
    horizon: ENV["HORIZON"]&.to_i,
    timeframe: ENV["TIMEFRAME"]
  }.compact
end
