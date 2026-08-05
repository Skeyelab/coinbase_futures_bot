require_relative "../lib/station_evidence"

RSpec.describe StationEvidence do
  # A day where every candidate station would have made the SAME call proves
  # nothing about which one settles the market. That is the trap already
  # recorded in cities.rb: every settled market resolved NO, so all three
  # candidate DC stations "matched" and none was distinguished.
  describe ".discriminating" do
    it "ignores a day where the candidates agree" do
      day = {
        date: "2026-08-04",
        ticker: "KXHIGHTDC-26AUG04-T83",
        settled: "no",
        calls: [{station: "KDCA", says: "refuted"}, {station: "KIAD", says: "refuted"}]
      }

      expect(described_class.discriminating([day])).to be_empty
    end

    it "keeps a day where the candidates split" do
      day = {
        date: "2026-08-04",
        ticker: "KXHIGHTDC-26AUG04-B83.5",
        settled: "yes",
        calls: [{station: "KDCA", says: "confirmed"}, {station: "KIAD", says: "refuted"}]
      }

      expect(described_class.discriminating([day])).to eq([day])
    end
  end

  # Settlement is the referee. On a split day the station whose call matched
  # what actually settled is right and every other candidate is wrong -- that
  # is the whole of the evidence, and one such day outweighs a month of
  # unanimous agreement.
  describe ".tally" do
    def split_day(date, settled, dca:, iad:)
      {date: date, ticker: "KXHIGHTDC-#{date}-B83.5", settled: settled,
       calls: [{station: "KDCA", says: dca}, {station: "KIAD", says: iad}]}
    end

    it "credits the station that matched settlement and faults the one that did not" do
      days = [split_day("2026-08-04", "yes", dca: "confirmed", iad: "refuted")]

      tally = described_class.tally(days)

      expect(tally["KDCA"]).to eq(wins: 1, losses: 0, days: ["2026-08-04"])
      expect(tally["KIAD"]).to eq(wins: 0, losses: 1, days: ["2026-08-04"])
    end
  end

  # The threshold, stated here rather than discovered later: zero misses across
  # at least three SEPARATE days. The thesis is arithmetic on a ratchet, so one
  # wrong call means this station's reading is not what settles the market. The
  # three-day floor stops a single lucky session promoting anybody.
  describe ".promotable" do
    def split_day(date, settled, dca:, iad:)
      {date: date, ticker: "KXHIGHTDC-#{date}-B83.5", settled: settled,
       calls: [{station: "KDCA", says: dca}, {station: "KIAD", says: iad}]}
    end

    it "promotes a station that wins three separate days with no misses" do
      days = %w[2026-08-04 2026-08-05 2026-08-06].map { |d|
        split_day(d, "yes", dca: "confirmed", iad: "refuted")
      }

      expect(described_class.promotable(days)).to eq(["KDCA"])
    end

    it "refuses on two days however clean" do
      days = %w[2026-08-04 2026-08-05].map { |d|
        split_day(d, "yes", dca: "confirmed", iad: "refuted")
      }

      expect(described_class.promotable(days)).to be_empty
    end

    # One miss is disqualifying. A station that reads the settling observation
    # correctly does not get it wrong once -- if it did, we are not doing
    # arithmetic, we are guessing with extra steps.
    it "refuses a station with any miss, however many wins" do
      days = %w[2026-08-04 2026-08-05 2026-08-06].map { |d|
        split_day(d, "yes", dca: "confirmed", iad: "refuted")
      } + [split_day("2026-08-07", "no", dca: "confirmed", iad: "refuted")]

      expect(described_class.promotable(days)).to eq(["KIAD"]).or be_empty
      expect(described_class.promotable(days)).not_to include("KDCA")
    end
  end
end
