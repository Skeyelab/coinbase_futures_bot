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
    it "distrusts a settled fact nobody has taken" do
      expect(described_class.doubts(episode(seconds: 300)).first).to match(/persisted/)
      expect(described_class.doubts(episode(seconds: 299))).to be_empty
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

    it "answers credible? from the same signals" do
      expect(described_class).to be_credible(episode)
      expect(described_class).not_to be_credible(episode(market_pct: 93))
    end

    it "lets the persistence threshold be tuned as evidence accumulates" do
      expect(described_class.doubts(episode(seconds: 400), max_persistence: 600)).to be_empty
      expect(described_class.doubts(episode(seconds: 400), max_persistence: 300).first)
        .to match(/persisted/)
    end
  end
end
