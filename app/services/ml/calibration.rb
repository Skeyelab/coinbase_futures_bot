# frozen_string_literal: true

module Ml
  # Out-of-sample calibration arithmetic for the #302 report: does the fitted
  # probability MEAN anything, and at which cutoff does the realized win rate
  # clear the bar? Pure functions over parallel prediction/outcome arrays.
  module Calibration
    module_function

    # Ten equal-count bins by ascending predicted probability. Each row:
    # {decile:, n:, mean_predicted:, realized_rate:}. A well-calibrated model
    # shows realized_rate tracking mean_predicted decile by decile.
    def decile_report(predictions, outcomes, bins: 10)
      pairs = paired(predictions, outcomes).sort_by { |p, _, i| [p, i] }

      base = pairs.size / bins
      remainder = pairs.size % bins
      offset = 0

      (0...bins).map do |b|
        size = base + ((b < remainder) ? 1 : 0)
        chunk = pairs[offset, size] || []
        offset += size

        {
          decile: b + 1,
          n: chunk.size,
          mean_predicted: chunk.empty? ? nil : chunk.sum { |p, _, _| p } / chunk.size,
          realized_rate: chunk.empty? ? nil : chunk.sum { |_, y, _| y }.to_f / chunk.size
        }
      end
    end

    # For each cutoff: how many observations clear it, and what fraction won.
    # realized_rate is nil (not 0.0) when nothing clears — an empty selection
    # is "no evidence", not "0% win rate".
    def cutoff_sweep(predictions, outcomes, cutoffs:)
      pairs = paired(predictions, outcomes)

      cutoffs.map do |cutoff|
        selected = pairs.select { |p, _, _| p >= cutoff }
        {
          cutoff: cutoff,
          n: selected.size,
          realized_rate: selected.empty? ? nil : selected.sum { |_, y, _| y }.to_f / selected.size
        }
      end
    end

    # The operating question: the LOWEST cutoff whose realized OOS win rate
    # clears target_rate — lowest because every higher cutoff trades volume
    # for the same or less certain evidence. nil when no cutoff clears.
    def operating_point(predictions, outcomes, target_rate:, cutoffs:)
      cutoff_sweep(predictions, outcomes, cutoffs: cutoffs.sort)
        .find { |row| row[:n].positive? && row[:realized_rate] >= target_rate }
    end

    def paired(predictions, outcomes)
      raise ArgumentError, "predictions/outcomes size mismatch" unless predictions.size == outcomes.size

      predictions.each_index.map { |i| [predictions[i].to_f, outcomes[i], i] }
    end
  end
end
