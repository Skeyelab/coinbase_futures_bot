# How long has this ticker been continuously sighted? The analyzer computes
# episode dwell after the fact; the executor needs the same number at sighting
# time, because persistence is a doubt signal (see Credibility) and a doubt
# must block the order BEFORE it is placed, not explain it afterwards.
module Execution
  class EpisodeTracker
    # Same default as the analyzer's EPISODE_GAP_SECONDS: sightings further
    # apart than this are separate episodes.
    DEFAULT_GAP = 300

    def initialize(gap: DEFAULT_GAP)
      @gap = gap
      @episodes = {}
    end

    # Returns seconds since this episode began. A sighting after more than
    # `gap` seconds of silence starts a new episode at zero.
    def observe(ticker, at:)
      episode = @episodes[ticker]

      if episode.nil? || at - episode[:last] > @gap
        @episodes[ticker] = {first: at, last: at}
        return 0
      end

      episode[:last] = at
      at - episode[:first]
    end
  end
end
