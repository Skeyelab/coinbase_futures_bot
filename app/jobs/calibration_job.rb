# frozen_string_literal: true

# Calibrates the LIVE strategy (issue #299, closes #163): grid-searches
# tp/sl candidates by running Strategy::MultiTimeframeSignal through the
# walk-forward backtest engine (out-of-sample evaluation), then persists the
# winner as a versioned, per-symbol TradingProfile and activates it so the
# live path picks it up via TradingProfile.effective(symbol:).
class CalibrationJob < ApplicationJob
  queue_as :default

  DEFAULT_TP_TARGETS = [0.004, 0.006, 0.008].freeze
  DEFAULT_SL_TARGETS = [0.003, 0.004, 0.005].freeze
  MIN_STEP_CANDLES = 100

  # Objectives score a walk-forward AGGREGATE (out-of-sample). Grid/random
  # only for v1; Bayesian search is a noted future enhancement.
  OBJECTIVES = {
    total_pnl: ->(agg) { agg[:total_pnl].to_f },
    drawdown_penalized: ->(agg) { agg[:total_pnl].to_f * (1.0 - agg[:worst_window_drawdown].to_f) }
  }.freeze

  def perform(symbols: nil, tp_targets: nil, sl_targets: nil, objective: :drawdown_penalized,
    lookback_days: 60, train_days: 14, eval_days: 7, step: "5m")
    @objective = objective.to_sym
    @scorer = OBJECTIVES.fetch(@objective)
    @tp_targets = Array(tp_targets.presence || DEFAULT_TP_TARGETS)
    @sl_targets = Array(sl_targets.presence || DEFAULT_SL_TARGETS)
    @lookback_days = lookback_days
    @train_days = train_days
    @eval_days = eval_days
    @step = step

    (symbols.presence || Contract.enabled.pluck(:product_id)).each do |symbol|
      calibrate_symbol(symbol)
    end
  end

  private

  def calibrate_symbol(symbol)
    from = @lookback_days.days.ago
    to = Time.current

    unless enough_data?(symbol, from)
      Rails.logger.info("[Calibrate] #{symbol}: insufficient #{@step} candles, skipping")
      return
    end

    scored = @tp_targets.product(@sl_targets).map do |tp, sl|
      evaluate_candidate(symbol, tp, sl, from, to)
    end
    best = scored.max_by { |c| c[:score] }

    if best[:aggregate][:trade_count].to_i.zero?
      Rails.logger.warn("[Calibrate] #{symbol}: best candidate produced no trades, not persisting")
      return
    end

    persist_profile(symbol, best, scored.size)
  end

  def evaluate_candidate(symbol, tp, sl, from, to)
    strategy = Strategy::MultiTimeframeSignal.new(resolve_symbols: false, tp_target: tp, sl_target: sl)
    report = Backtest::WalkForward.new(symbol: symbol, strategy: strategy, step: @step)
      .run(from: from, to: to, train_span: @train_days.days, eval_span: @eval_days.days)
    aggregate = report[:aggregate]

    {tp_target: tp, sl_target: sl, aggregate: aggregate, score: @scorer.call(aggregate)}
  end

  def persist_profile(symbol, best, candidates_evaluated)
    profile = TradingProfile.create!(
      name: "calibrated #{symbol} #{Time.current.utc.iso8601}",
      symbol: symbol,
      tp_target: best[:tp_target],
      sl_target: best[:sl_target],
      calibrated_at: Time.current,
      description: "Auto-calibrated via walk-forward backtest (#{@objective})",
      metrics: {
        objective: @objective,
        score: best[:score],
        aggregate: best[:aggregate],
        candidates_evaluated: candidates_evaluated,
        lookback_days: @lookback_days,
        train_days: @train_days,
        eval_days: @eval_days,
        step: @step
      }
    )
    profile.activate!
    Rails.logger.info("[Calibrate] #{symbol}: activated profile #{profile.id} " \
                      "tp=#{best[:tp_target]} sl=#{best[:sl_target]} score=#{best[:score].round(2)}")
    profile
  end

  def enough_data?(symbol, from)
    scope = {"1m" => :one_minute, "5m" => :five_minute, "15m" => :fifteen_minute, "1h" => :hourly}.fetch(@step)
    Candle.for_symbol(symbol).public_send(scope).where(timestamp: from..).count >= MIN_STEP_CANDLES
  end
end
