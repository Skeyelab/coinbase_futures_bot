# frozen_string_literal: true

# Issue #568: maker-band mean reversion evaluation (memo candidate B).
#
#   bin/rails "maker_band:walk_forward[BIP-20DEC30-CDE,2025-08-01,2026-07-27]"
#   bin/rails "maker_band:gates[BIP-20DEC30-CDE,2025-08-01,2026-07-27]"
#
# Symbols are used as-is against stored candles. Both tasks replay with
# fill_model: :through_price (resting limits fill only when a bar trades
# strictly THROUGH them) and maker_fee_rate 0 — the venue's promo maker rate;
# the taker rate still applies to stop exits. Strategy knobs override via
# ENV: ANCHOR_PERIOD, VOL_PERIOD, BAND_K, STOP_M, MIN_BAND_BPS, CONTRACTS,
# CONTRACT_SIZE_USD.
namespace :maker_band do
  def maker_band_config
    {anchor_period: ENV["ANCHOR_PERIOD"]&.to_i, vol_period: ENV["VOL_PERIOD"]&.to_i,
     band_k: ENV["BAND_K"]&.to_f, stop_m: ENV["STOP_M"]&.to_f,
     min_band_bps: ENV["MIN_BAND_BPS"]&.to_f, contracts: ENV["CONTRACTS"]&.to_i,
     contract_size_usd: ENV["CONTRACT_SIZE_USD"]&.to_f}.compact
  end

  desc "Walk-forward MakerBandReversion (through-price fills); prints JSON report"
  task :walk_forward, %i[symbol from to train_days eval_days] => :environment do |_t, args|
    symbol = args[:symbol] || ENV.fetch("SYMBOL")
    from = Time.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.parse(args[:to] || ENV.fetch("TO"))
    train_days = (args[:train_days] || ENV["TRAIN_DAYS"] || 14).to_i
    eval_days = (args[:eval_days] || ENV["EVAL_DAYS"] || 7).to_i

    engine_options = {symbol: symbol, step: "5m",
                      strategy: Strategy::MakerBandReversion.new(maker_band_config),
                      fill_model: :through_price, maker_fee_rate: 0.0}
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

  desc "Walk-forward + ParameterPlateau (5x5 N/k) + PessimisticCost (1.5x/2x); prints verdicts"
  task :gates, %i[symbol from to train_days eval_days] => :environment do |_t, args|
    symbol = args[:symbol] || ENV.fetch("SYMBOL")
    from = Time.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.parse(args[:to] || ENV.fetch("TO"))
    train_days = (args[:train_days] || ENV["TRAIN_DAYS"] || 14).to_i
    eval_days = (args[:eval_days] || ENV["EVAL_DAYS"] || 7).to_i

    result = Backtest::MakerBandEvaluation.run(symbol: symbol, from: from, to: to,
      train_span: train_days.days, eval_span: eval_days.days, config: maker_band_config)

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
