require_relative "../lib/touch_scan"

RSpec.describe TouchScan do
  describe "the RTI settlement block" do
    # Kalshi settles crypto against CF Benchmarks' Real Time Index, not against
    # any single venue's spot. PriceExtremes reads Coinbase. Near a strike that
    # difference decides the outcome, so every one-touch verdict this produced
    # was built on the wrong number.
    #
    # Disabled rather than approximated: a scanner that stays quiet is harmless,
    # but one that would confidently report a false opportunity the moment BTC
    # neared $60,000 is worse than having none.
    it "is switched off, with the reason recorded" do
      expect(described_class::ENABLED).to be(false)
      expect(described_class::DISABLED_REASON).to match(/CF Benchmarks|RTI/i)
    end

    it "returns no opportunities at all while disabled" do
      results = described_class.new(client: :should_never_be_touched).run

      expect(results).to all(satisfy { |r| r.opportunities.empty? })
      expect(results.map(&:error)).to all(match(/disabled/i))
    end

    # The guard has to sit before any network call, or a disabled scanner still
    # burns rate limit and still depends on the wrong price source.
    it "does no work at all, not merely discarded work" do
      client = double("client")
      expect(client).not_to receive(:series_markets)

      described_class.new(client: client).run
    end
  end
end
