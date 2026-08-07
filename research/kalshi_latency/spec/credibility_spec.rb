require_relative "../lib/credibility"

RSpec.describe Credibility do
  def episode(market_pct: 0, support: 5, seconds: 30, net: 20, contracts: 100)
    {market_pct: market_pct, support: support, seconds: seconds, net: net, contracts: contracts}
  end

  describe ".doubts" do
    it "finds nothing wrong with a fresh, corroborated, uncontested episode" do
      expect(described_class.doubts(episode)).to be_empty
    end

    it "distrusts a claim the book disputes" do
      expect(described_class.doubts(episode(market_pct: 20)).first).to match(/disagrees/)
      expect(described_class.doubts(episode(market_pct: 19))).to be_empty
    end

    it "distrusts a peak standing on one observation" do
      expect(described_class.doubts(episode(support: 1)).first).to match(/lone spike/)
      expect(described_class.doubts(episode(support: 2))).to be_empty
    end

    # THE INVERTED ONE. For a news-latency trade a long window is the edge. For
    # a settled fact it is the tell: the real one observed vanished in 70
    # seconds, and the false one sat for 2,205.
    # Since 2026-08-07 this doubt applies only where it was earned: an episode
    # the market DISPUTES. Agreement excuses it (see the conditioned describe
    # block below for the measurement).
    it "distrusts a disputed settled fact nobody has taken" do
      disputed = {market_pct: 93, support: 5}
      expect(described_class.doubts(disputed.merge(seconds: 300))).to include(a_string_matching(/persisted/))
      expect(described_class.doubts(disputed.merge(seconds: 299))).not_to include(a_string_matching(/persisted/))
    end

    it "reports every reason, not just the first" do
      reasons = described_class.doubts(episode(market_pct: 93, support: 1, seconds: 2205))

      expect(reasons.size).to eq(3)
      expect(reasons.join).to match(/disagrees.*lone spike.*persisted/m)
    end

    # Support is absent for families that have no notion of it, and absence is
    # not a doubt -- it would make every non-weather episode permanently
    # untrustworthy.
    it "does not treat missing support as a lone spike" do
      expect(described_class.doubts(episode(support: nil))).to be_empty
    end

    # A city whose settlement station we inferred rather than read cannot
    # produce a tradeable signal, however clean it otherwise looks.
    it "distrusts an unverified settlement station" do
      expect(described_class.doubts(episode.merge(verified: false)).first)
        .to match(/station unverified/)
      expect(described_class.doubts(episode.merge(verified: true))).to be_empty
    end

    it "treats an absent verified flag as verified, not as a doubt" do
      expect(described_class.doubts(episode)).to be_empty
    end

    it "answers credible? from the same signals" do
      expect(described_class).to be_credible(episode)
      expect(described_class).not_to be_credible(episode(market_pct: 93))
    end

    it "lets the persistence threshold be tuned as evidence accumulates" do
      disputed = {market_pct: 93, support: 5, seconds: 400}
      expect(described_class.doubts(disputed, max_persistence: 600))
        .not_to include(a_string_matching(/persisted/))
      expect(described_class.doubts(disputed, max_persistence: 300))
        .to include(a_string_matching(/persisted/))
    end
  end

  # Measured 2026-08-07 over 25 scored episodes (Aug 4-6). Market agreement
  # is a perfect separator on that sample: 11/11 correct when the book agreed
  # (<20%), 4/14 when it disputed. Conditioned on agreement, PERSISTENCE adds
  # nothing -- 10/10 slow-but-agreeing episodes settled our way, several
  # sitting 45-75 minutes. The rule's premise ("a real fact gets taken fast")
  # assumed a counterparty; the measured counterparty rate on dead buckets is
  # 5.9%, so slowness measures an empty book, not our error.
  describe "persistence, conditioned on market agreement" do
    it "does not doubt a long-lived episode the market agrees with" do
      episode = {market_pct: 7, support: 3, seconds: 1081, verified: true}

      expect(described_class.doubts(episode)).to be_empty
    end

    it "still doubts a long-lived episode the market disputes" do
      # KXHIGHLAX-26AUG04-B77.5: 19,041s at 99% disagreement. It settled YES.
      # This is the episode persistence was created for and it must stay caught.
      episode = {market_pct: 99, support: 1, seconds: 19_041, verified: true}
      doubts = described_class.doubts(episode)

      expect(doubts).to include("market disagrees 99%")
      expect(doubts).to include(a_string_matching(/persisted/))
    end

    it "doubts a long-lived episode when agreement is unknown" do
      # No market_pct recorded reads as 0, which would silently mean "agrees".
      # Absent evidence of agreement, persistence keeps its say.
      episode = {support: 3, seconds: 4000, verified: true}

      expect(described_class.doubts(episode)).to include(a_string_matching(/persisted/))
    end
  end
end
