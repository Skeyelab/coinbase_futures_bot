# How long a market took to absorb a scheduled release.
#
# The whole thesis reduces to one number: the gap between the moment a figure
# becomes public and the moment the book has mostly finished repricing. If that
# is a second, a retail setup is racing machines. If it is a minute, it is
# racing people reading a headline.
#
# Times are absolute epoch floats so the release stream and the book stream can
# be subtracted directly.
module Convergence
  def self.measure(mids, published_at:, move_threshold: 3.0, settle_samples: 3)
    before = mids.select { |m| m[:at] < published_at }
    after = mids.select { |m| m[:at] >= published_at }
    return blank if before.empty? || after.empty?

    pre = median(before.last(settle_samples).map { |m| m[:mid] })
    settled = median(after.last(settle_samples).map { |m| m[:mid] })
    move = (settled - pre).abs

    {
      pre_mid: pre,
      settled_mid: settled,
      move_cents: move.round(4),
      samples_after: after.size,
      # A move too small to trade is not a reaction worth timing.
      seconds_to_first_move: (move >= move_threshold) ? elapsed(after, published_at, pre, move_threshold) : nil,
      seconds_to_half: (move >= move_threshold) ? elapsed(after, published_at, pre, move * 0.5) : nil,
      seconds_to_ninety: (move >= move_threshold) ? elapsed(after, published_at, pre, move * 0.9) : nil
    }
  end

  # First sample that has travelled `distance` from the pre-release mid.
  def self.elapsed(after, published_at, pre, distance)
    hit = after.find { |m| (m[:mid] - pre).abs >= distance }
    hit && (hit[:at] - published_at).round(3)
  end

  def self.median(values)
    return nil if values.empty?

    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0)
  end

  def self.blank
    {pre_mid: nil, settled_mid: nil, move_cents: nil, samples_after: 0,
     seconds_to_first_move: nil, seconds_to_half: nil, seconds_to_ninety: nil}
  end
end
