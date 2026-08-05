# Finds significant price moves in a mid-price series and measures how long
# each one took to play out.
#
# This is the number the whole experiment exists to produce. A move that
# completes in one tick is not tradeable by anyone reacting to news. A move
# that takes minutes is a window.
module MoveAnalysis
  def self.detect(samples, threshold_cents:)
    moves = []
    i = 0

    while i < samples.size - 1
      peak = furthest_from(samples, i)
      excursion = samples[peak][:mid] - samples[i][:mid]

      if excursion.abs >= threshold_cents
        moves << {
          started_at: samples[i][:at],
          from_cents: samples[i][:mid],
          to_cents: samples[peak][:mid],
          magnitude_cents: excursion.abs,
          seconds_to_half: elapsed_to_fraction(samples, i, peak, 0.5),
          seconds_to_ninety: elapsed_to_fraction(samples, i, peak, 0.9),
          duration_seconds: samples[peak][:at] - samples[i][:at]
        }
        i = peak
      else
        i += 1
      end
    end

    moves
  end

  # Seconds from the move's start until price had covered `fraction` of the
  # total excursion. This is the reaction window: act after it and you are
  # paying for a repricing that already happened.
  def self.elapsed_to_fraction(samples, origin, peak, fraction)
    base = samples[origin][:mid]
    target = (samples[peak][:mid] - base).abs * fraction

    crossing = (origin..peak).find { |k| (samples[k][:mid] - base).abs >= target }
    samples[crossing][:at] - samples[origin][:at]
  end

  # Index of the sample that travels furthest from `origin` in either direction.
  def self.furthest_from(samples, origin)
    base = samples[origin][:mid]
    ((origin + 1)...samples.size).max_by { |j| (samples[j][:mid] - base).abs }
  end
end
