# Which station actually settles a market, decided by evidence rather than by
# which one looks obvious.
#
# The naive test -- "a day of its own predictions scored clean" -- cannot work,
# and cities.rb already records why: nearly every weather bucket settles NO, so
# every candidate station agrees, and agreement distinguishes nobody. An
# attempt to verify the twelve inferred stations that way failed exactly there.
#
# So only DISAGREEMENT counts. When two candidate stations for the same city
# would have made different calls, settlement picks a winner, and that single
# day is worth more than a month of unanimous refutations.
module StationEvidence
  module_function

  # Stated before the evidence, in the funding-gate style, so it cannot be
  # moved later to fit a station we want promoted.
  REQUIRED_DAYS = 3

  # A settled market maps to the call that would have been right about it:
  # settling YES means the contract was confirmed, NO means refuted.
  SETTLED_AS = {"yes" => "confirmed", "no" => "refuted"}.freeze

  # Days where the candidates did not all say the same thing.
  def discriminating(days)
    days.select { |day| day[:calls].map { |c| c[:says] }.uniq.size > 1 }
  end

  # Settlement is the referee. On a split day the station whose call matched
  # what settled is right and every other candidate is wrong.
  def tally(days)
    result = Hash.new { |h, k| h[k] = {wins: 0, losses: 0, days: []} }

    discriminating(days).each do |day|
      truth = SETTLED_AS[day[:settled]]
      day[:calls].each do |call|
        row = result[call[:station]]
        (call[:says] == truth) ? row[:wins] += 1 : row[:losses] += 1
        row[:days] << day[:date] unless row[:days].include?(day[:date])
      end
    end

    result
  end

  # Stations that have earned the verified flag. Zero misses across at least
  # REQUIRED_DAYS separate days of genuine disagreement -- days where the
  # candidates agreed never enter the tally and so cannot pad this.
  def promotable(days)
    tally(days).select { |_station, row|
      row[:losses].zero? && row[:days].size >= REQUIRED_DAYS
    }.keys
  end
end
