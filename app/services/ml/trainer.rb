# frozen_string_literal: true

module Ml
  # Fits the pooled logistic scorer and freezes it as a ScorerArtifact —
  # issue #302 steps 2-4 glued together.
  #
  # Split discipline (the PRD's honest-n caveat): TIME-based only, never
  # random. Consecutive bars share almost their entire forward window, so a
  # random split trains on the eval set's near-duplicates. Train takes the
  # first `train_fraction` of the span; bars whose label window CROSSES the
  # cutoff are embargoed — dropped from both sides — so no training label
  # peeks into evaluation time.
  #
  # Standardization constants come from TRAIN rows only (eval statistics are
  # future information) and are stored in the artifact, so scoring reproduces
  # the exact training-time transform forever.
  class Trainer
    TARGET_WIN_RATE = 0.40 # the #568 round-2 bar the fitted scorer must clear
    PROBABILITY_CUTOFFS = (5..95).step(5).map { |i| i / 100.0 }.freeze
    SECONDS_PER_YEAR = 365.25 * 86_400

    STEP_SECONDS = {"1m" => 60, "5m" => 300, "15m" => 900, "1h" => 3600}.freeze

    def initialize(symbols:, direction:, from:, to:, tp_frac:, sl_frac:, horizon:,
      timeframe: "5m", train_fraction: 0.7, extractor_config: {}, version: nil, l2: LogisticRegression::DEFAULT_L2)
      @symbols = symbols
      @direction = direction
      @from = from
      @to = to
      @tp_frac = tp_frac
      @sl_frac = sl_frac
      @horizon = horizon
      @timeframe = timeframe
      @train_fraction = train_fraction
      @extractor_config = FeatureExtractor::DEFAULTS.merge(extractor_config)
      @version = version || "logistic-#{direction}-#{Time.current.utc.strftime("%Y%m%d%H%M%S")}"
      @l2 = l2
    end

    # Pure split rule, exposed for direct testing. Returns index buckets:
    #   train     — ts + embargo_seconds <= cutoff (label resolved pre-cutoff)
    #   embargoed — ts <= cutoff but the label window crosses it
    #   eval      — ts > cutoff
    def self.time_split(timestamps, from:, to:, train_fraction:, embargo_seconds:)
      cutoff = from + train_fraction * (to - from)
      split = {cutoff: cutoff, train: [], embargoed: [], eval: []}

      timestamps.each_with_index do |ts, i|
        bucket = if ts + embargo_seconds <= cutoff
          :train
        elsif ts <= cutoff
          :embargoed
        else
          :eval
        end
        split[bucket] << i
      end

      split
    end

    # Index selection at pooled scale. values_at(*indices) would pass every
    # index as a VM stack argument — fine at spec size, SystemStackError at
    # the ~300k indices a 4-symbol pooled fit produces.
    def self.select_rows(rows, indices)
      indices.map { |i| rows[i] }
    end

    # Fits, evaluates out-of-sample, persists and FREEZES the artifact.
    # Returns {artifact:, report:}.
    def run
      rows = DatasetBuilder.new(symbols: @symbols, direction: @direction,
        tp_frac: @tp_frac, sl_frac: @sl_frac, horizon: @horizon,
        timeframe: @timeframe, extractor_config: @extractor_config)
        .rows(from: @from, to: @to)
      raise ArgumentError, "no labeled bars with features in range" if rows.empty?

      split = self.class.time_split(rows.map { |r| r[:timestamp] },
        from: @from, to: @to, train_fraction: @train_fraction,
        embargo_seconds: @horizon * STEP_SECONDS.fetch(@timeframe))

      # NOT values_at(*indices): splatting ~300k pooled indices as method
      # arguments blows the VM stack (SystemStackError on the first 4-symbol
      # fit, 2026-07-29). map is allocation-equivalent and stack-flat.
      train_rows = self.class.select_rows(rows, split[:train])
      eval_rows = self.class.select_rows(rows, split[:eval])
      raise ArgumentError, "train side is empty — widen the range" if train_rows.empty?
      raise ArgumentError, "eval side is empty — widen the range" if eval_rows.empty?

      standardization = train_standardization(train_rows)
      model = LogisticRegression.fit(
        design_matrix(train_rows, standardization),
        train_rows.map { |r| r[:y] },
        l2: @l2
      )

      predictions = design_matrix(eval_rows, standardization)
        .map { |x| model.predict_probability(x) }
      outcomes = eval_rows.map { |r| r[:y] }
      evaluation = evaluate(predictions, outcomes, split[:cutoff])

      report = build_report(rows, split, train_rows, eval_rows, model, evaluation)
      artifact = persist_artifact(standardization, model, report)

      {artifact: artifact, report: report}
    end

    private

    def feature_names
      FeatureExtractor::FEATURE_NAMES
    end

    # One dummy per non-baseline symbol; the first symbol is the baseline the
    # intercept absorbs.
    def dummy_names
      @symbols[1..].map { |symbol| "symbol=#{symbol}" }
    end

    def train_standardization(train_rows)
      means = {}
      stds = {}

      feature_names.each do |name|
        values = train_rows.map { |row| row[:features].fetch(name) }
        mean = values.sum / values.size
        variance = if values.size < 2
          0.0
        else
          values.sum { |v| (v - mean)**2 } / (values.size - 1)
        end
        std = Math.sqrt(variance)

        means[name] = mean
        # A constant feature carries no information; unit scale keeps its
        # z-scores finite instead of exploding through a ~0 divisor.
        stds[name] = (std > 1e-12) ? std : 1.0
      end

      {"means" => means, "stds" => stds}
    end

    def design_matrix(rows, standardization)
      means = standardization.fetch("means")
      stds = standardization.fetch("stds")

      rows.map do |row|
        x = feature_names.map do |name|
          (row[:features].fetch(name) - means.fetch(name)) / stds.fetch(name)
        end
        @symbols[1..].each { |symbol| x << ((row[:symbol] == symbol) ? 1.0 : 0.0) }
        x
      end
    end

    def evaluate(predictions, outcomes, cutoff)
      eval_years = (@to - cutoff).to_f / SECONDS_PER_YEAR
      per_year = ->(n) { (eval_years > 0) ? (n / eval_years).round(1) : nil }

      cutoffs = Calibration.cutoff_sweep(predictions, outcomes, cutoffs: PROBABILITY_CUTOFFS)
        .map { |row| row.merge(per_year: per_year.call(row[:n])) }
      operating_point = Calibration.operating_point(predictions, outcomes,
        target_rate: TARGET_WIN_RATE, cutoffs: PROBABILITY_CUTOFFS)
        &.then { |row| row.merge(per_year: per_year.call(row[:n])) }

      {
        deciles: Calibration.decile_report(predictions, outcomes),
        cutoffs: cutoffs,
        operating_point: operating_point,
        target_win_rate: TARGET_WIN_RATE,
        eval_years: eval_years.round(4)
      }
    end

    def build_report(rows, split, train_rows, eval_rows, model, evaluation)
      {
        version: @version,
        direction: @direction,
        shape: {tp_frac: @tp_frac, sl_frac: @sl_frac, horizon: @horizon, timeframe: @timeframe},
        dataset: {
          symbols: @symbols,
          from: @from,
          to: @to,
          cutoff_at: split[:cutoff],
          rows_total: rows.size,
          train_rows: train_rows.size,
          embargoed_rows: split[:embargoed].size,
          eval_rows: eval_rows.size,
          base_rate_train: rate(train_rows),
          base_rate_eval: rate(eval_rows)
        },
        fit: {
          iterations: model.iterations,
          converged: model.converged,
          intercept: model.intercept,
          weights: named_weights(model)
        },
        evaluation: evaluation
      }
    end

    def rate(rows)
      (rows.sum { |r| r[:y] }.to_f / rows.size).round(4)
    end

    def named_weights(model)
      (feature_names + dummy_names).zip(model.weights).to_h
    end

    def persist_artifact(standardization, model, report)
      artifact = ScorerArtifact.create!(
        version: @version,
        kind: "logistic_v1",
        direction: @direction,
        timeframe: @timeframe,
        tp_frac: @tp_frac,
        sl_frac: @sl_frac,
        horizon: @horizon,
        feature_spec: {
          "feature_names" => feature_names,
          "symbols" => @symbols,
          "baseline_symbol" => @symbols.first,
          "standardization" => standardization,
          "extractor_config" => @extractor_config
        },
        coefficients: {
          "intercept" => model.intercept,
          "weights" => named_weights(model)
        },
        training_metadata: report.except(:version)
      )
      artifact.freeze_artifact!
      artifact
    end
  end
end
