# frozen_string_literal: true

# Event-driven backtesting of the live strategy (issue #298).
#
#   bin/rails "backtest:run[BTC-USD,2026-06-01,2026-07-01]"
#   bin/rails "backtest:walk_forward[BTC-USD,2026-04-01,2026-07-01,14,7]"
#
# Symbols are used as-is against stored candles (no contract resolution).
# Fees default to taker pricing; override with BACKTEST_TAKER_FEE_RATE.
namespace :backtest do
  desc "Backtest MultiTimeframeSignal over candle history; prints JSON metrics"
  task :run, %i[symbol from to step] => :environment do |_t, args|
    symbol = args[:symbol] || ENV["SYMBOL"] || "BTC-USD"
    from = Time.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.parse(args[:to] || ENV.fetch("TO"))
    step = args[:step] || ENV["STEP"] || "5m"

    result = Backtest::Engine.new(symbol: symbol, step: step).run(from: from, to: to)
    puts JSON.pretty_generate(result.to_h)
  end

  desc "Walk-forward evaluation: rolling out-of-sample windows; prints JSON report"
  task :walk_forward, %i[symbol from to train_days eval_days step] => :environment do |_t, args|
    symbol = args[:symbol] || ENV["SYMBOL"] || "BTC-USD"
    from = Time.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.parse(args[:to] || ENV.fetch("TO"))
    train_days = (args[:train_days] || ENV["TRAIN_DAYS"] || 14).to_i
    eval_days = (args[:eval_days] || ENV["EVAL_DAYS"] || 7).to_i
    step = args[:step] || ENV["STEP"] || "5m"

    report = Backtest::WalkForward.new(symbol: symbol, step: step)
      .run(from: from, to: to, train_span: train_days.days, eval_span: eval_days.days)
    puts JSON.pretty_generate(report)
  end
end
