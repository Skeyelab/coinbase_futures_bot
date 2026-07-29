# frozen_string_literal: true

# Issue #568 rank-3 / #569: funding-skew contrarian evaluation, driven by the
# basis proxy (hourly perp-vs-spot premium from stored 1m candles).
#
#   bin/rails "funding_skew:cross_validate[BIP-20DEC30-CDE,BTC-USD,2026-07-01,2026-07-28]"
#   bin/rails "funding_skew:walk_forward[BIP-20DEC30-CDE,BTC-USD,2025-08-01,2026-07-27]"
#   bin/rails "funding_skew:gates[BIP-20DEC30-CDE,BTC-USD,2025-08-01,2026-07-27]"
#
# Symbols are used as-is against stored candles. Fills are the default taker
# model (:touch + venue taker fee) — taker costs are part of this candidate's
# test. Strategy knobs override via ENV: ENTRY_Z, EXIT_Z, WINDOW (hours),
# STOP (fraction), CONTRACTS, CONTRACT_SIZE_USD.
namespace :funding_skew do
  def funding_skew_config(spot_symbol)
    {entry_z: ENV["ENTRY_Z"]&.to_f, exit_z: ENV["EXIT_Z"]&.to_f,
     window: ENV["WINDOW"]&.to_i, stop: ENV["STOP"]&.to_f,
     contracts: ENV["CONTRACTS"]&.to_i, contract_size_usd: ENV["CONTRACT_SIZE_USD"]&.to_f,
     spot_symbol: spot_symbol}.compact
  end

  desc "Correlate the basis proxy against stored funding_rates snapshots; prints {n:, r:}"
  task :cross_validate, %i[symbol spot from to] => :environment do |_t, args|
    symbol = args[:symbol] || ENV.fetch("SYMBOL")
    spot = args[:spot] || ENV["SPOT_SYMBOL"] || "BTC-USD"
    from = Time.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.parse(args[:to] || ENV.fetch("TO"))

    result = Signals::FundingProxy.new(perp_symbol: symbol, spot_symbol: spot)
      .correlation_with_funding(from: from, to: to)

    # #569 validated r = 0.77 on 143 overlapping hours; a collapse below ~0.7
    # as snapshots accrue means the proxy is no longer a usable stand-in.
    puts JSON.pretty_generate(result.merge(symbol: symbol, spot: spot,
      from: from.iso8601, to: to.iso8601))
  end

  desc "Walk-forward FundingSkewContrarian (1h step, taker fills); prints JSON report"
  task :walk_forward, %i[symbol spot from to train_days eval_days] => :environment do |_t, args|
    symbol = args[:symbol] || ENV.fetch("SYMBOL")
    spot = args[:spot] || ENV["SPOT_SYMBOL"] || "BTC-USD"
    from = Time.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.parse(args[:to] || ENV.fetch("TO"))
    train_days = (args[:train_days] || ENV["TRAIN_DAYS"] || 14).to_i
    eval_days = (args[:eval_days] || ENV["EVAL_DAYS"] || 7).to_i

    engine_options = {symbol: symbol, step: "1h",
                      strategy: Strategy::FundingSkewContrarian.new(funding_skew_config(spot))}
    engine = Backtest::Engine.new(**engine_options)
    started_at = Time.current

    begin
      report = Backtest::WalkForward.new(**engine_options)
        .run(from: from, to: to, train_span: train_days.days, eval_span: eval_days.days)
    rescue => e
      Backtest::RunRecorder.record_failure(engine: engine, from: from, to: to, kind: "walk_forward",
        error: e, started_at: started_at, finished_at: Time.current)
      raise
    end

    run = Backtest::RunRecorder.record_walk_forward(engine: engine, report: report,
      from: from, to: to, train_days: train_days, eval_days: eval_days,
      started_at: started_at, finished_at: Time.current)

    puts JSON.pretty_generate(report)
    warn "recorded as BacktestRun ##{run.id}"
  end

  desc "Walk-forward + ParameterPlateau (5x5 window/entry_z) + PessimisticCost (1.5x/2x); prints verdicts"
  task :gates, %i[symbol spot from to train_days eval_days] => :environment do |_t, args|
    symbol = args[:symbol] || ENV.fetch("SYMBOL")
    spot = args[:spot] || ENV["SPOT_SYMBOL"] || "BTC-USD"
    from = Time.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.parse(args[:to] || ENV.fetch("TO"))
    train_days = (args[:train_days] || ENV["TRAIN_DAYS"] || 14).to_i
    eval_days = (args[:eval_days] || ENV["EVAL_DAYS"] || 7).to_i

    result = Backtest::FundingSkewEvaluation.run(symbol: symbol, from: from, to: to,
      train_span: train_days.days, eval_span: eval_days.days,
      config: funding_skew_config(spot))

    # Verdicts and aggregates only — 26 walk-forward reports of window detail
    # would bury the two booleans this task exists to print.
    puts JSON.pretty_generate({
      config: result[:config],
      aggregate: result[:walk_forward][:aggregate],
      window_count: result[:walk_forward][:windows].size,
      plateau: result[:plateau].except(:cells),
      pessimistic_cost: result[:pessimistic_cost],
      passed: result[:passed]
    })
  end
end
