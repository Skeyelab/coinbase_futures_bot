# frozen_string_literal: true

# Fitted confidence scorer — issue #302 steps 2-4.
#
# Fit on the box (labels from labels:generate must already exist):
#
#   bin/rails "ml:fit[BIP-20DEC30-CDE:ETP-20DEC30-CDE:SLP-20DEC30-CDE:XPP-20DEC30-CDE,2025-08-01,2026-07-01,long]"
#
# Symbols are colon-separated (rake owns the comma). Optional ENV:
#   TP_FRAC / SL_FRAC / HORIZON / TIMEFRAME — label shape (defaults: the
#     measured #497 200/120 at a 288-bar horizon)
#   VERSION        — artifact version string (default: logistic-<dir>-<utc timestamp>)
#   TRAIN_FRACTION — time-based split point (default 0.7)
#
# Re-report an existing frozen artifact on any range (e.g. fresh data since
# the fit):
#
#   bin/rails "ml:evaluate[logistic-long-20260729120000,2026-05-01,2026-07-01]"
#
# Reading the report:
#   * deciles — eval bars sorted by predicted P(win), split into 10 equal
#     bins. Calibration means realized_rate tracks mean_predicted per bin.
#   * cutoffs — for each probability floor: bars clearing it, realized win
#     rate, and bars/year. Bars, not trades: overlapping horizons mean
#     consecutive selected bars are near-duplicates of one opportunity.
#   * operating_point — the lowest cutoff whose realized OOS win rate clears
#     40% (the #568 round-2 bar). null means the fitted scorer cannot isolate
#     a >40% subset on this data — the honest kill signal.
namespace :ml do
  desc "Fit the pooled logistic scorer, print the OOS report, persist a frozen artifact"
  task :fit, %i[symbols from to direction] => :environment do |_t, args|
    symbols = (args[:symbols] || ENV.fetch("SYMBOLS")).split(":").map(&:strip).reject(&:empty?)
    from = Time.zone.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.zone.parse(args[:to] || ENV.fetch("TO"))
    direction = args[:direction] || ENV.fetch("DIRECTION", "long")

    trainer = Ml::Trainer.new(symbols: symbols, direction: direction, from: from, to: to,
      train_fraction: ENV.fetch("TRAIN_FRACTION", "0.7").to_f,
      version: ENV["VERSION"].presence,
      **ml_shape_from_env)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = trainer.run
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    puts JSON.pretty_generate(result[:report].merge(
      artifact_id: result[:artifact].id,
      frozen_at: result[:artifact].frozen_at,
      elapsed_seconds: elapsed.round(2)
    ))
  end

  desc "Score a range with an existing frozen artifact and print the calibration report"
  task :evaluate, %i[version from to] => :environment do |_t, args|
    artifact = ScorerArtifact.find_by(version: args[:version] || ENV.fetch("VERSION"))
    abort("no artifact with that version — run ml:fit first") unless artifact

    from = Time.zone.parse(args[:from] || ENV.fetch("FROM"))
    to = Time.zone.parse(args[:to] || ENV.fetch("TO"))

    rows = Ml::DatasetBuilder.new(
      symbols: artifact.feature_spec.fetch("symbols"),
      direction: artifact.direction,
      timeframe: artifact.timeframe,
      tp_frac: artifact.tp_frac.to_f,
      sl_frac: artifact.sl_frac.to_f,
      horizon: artifact.horizon,
      extractor_config: artifact.feature_spec.fetch("extractor_config", {}).symbolize_keys
    ).rows(from: from, to: to)
    abort("no labeled bars with features in range") if rows.empty?

    scorer = Ml::ArtifactScorer.new(artifact)
    predictions = rows.map { |row| scorer.score(symbol: row[:symbol], features: row[:features]) }
    outcomes = rows.map { |row| row[:y] }

    years = (to - from).to_f / Ml::Trainer::SECONDS_PER_YEAR
    per_year = ->(n) { (years > 0) ? (n / years).round(1) : nil }
    cutoffs = Ml::Calibration.cutoff_sweep(predictions, outcomes, cutoffs: Ml::Trainer::PROBABILITY_CUTOFFS)
      .map { |row| row.merge(per_year: per_year.call(row[:n])) }
    operating_point = Ml::Calibration.operating_point(predictions, outcomes,
      target_rate: Ml::Trainer::TARGET_WIN_RATE, cutoffs: Ml::Trainer::PROBABILITY_CUTOFFS)
      &.then { |row| row.merge(per_year: per_year.call(row[:n])) }

    puts JSON.pretty_generate({
      version: artifact.version,
      direction: artifact.direction,
      from: from, to: to,
      rows: rows.size,
      base_rate: (outcomes.sum.to_f / outcomes.size).round(4),
      deciles: Ml::Calibration.decile_report(predictions, outcomes),
      cutoffs: cutoffs,
      operating_point: operating_point,
      target_win_rate: Ml::Trainer::TARGET_WIN_RATE
    })
  end
end

def ml_shape_from_env
  {
    tp_frac: ENV.fetch("TP_FRAC", Labels::PathDependent::DEFAULT_TP_FRAC.to_s).to_f,
    sl_frac: ENV.fetch("SL_FRAC", Labels::PathDependent::DEFAULT_SL_FRAC.to_s).to_f,
    horizon: ENV.fetch("HORIZON", Labels::PathDependent::DEFAULT_HORIZON.to_s).to_i,
    timeframe: ENV.fetch("TIMEFRAME", Labels::PathDependent::DEFAULT_TIMEFRAME)
  }
end
