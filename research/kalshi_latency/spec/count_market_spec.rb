require_relative "../lib/count_market"

RSpec.describe CountMarket do
  # Verified against live KXTRUTHSOCIAL-26AUG08 markets:
  #   B189  between floor=180 cap=199   "180-199"
  #   T240  greater floor=240           ">240"
  def bucket = described_class.new(ticker: "B189", kind: :between, floor: 180, cap: 199)
  def above = described_class.new(ticker: "T240", kind: :greater, floor: 240, cap: nil)

  describe "#status_given" do
    # A cumulative count only rises, so overshooting a bucket kills it forever.
    it "kills a bucket once the count passes its top" do
      expect(bucket.status_given(200)).to eq(:refuted)
      expect(bucket.status_given(199)).to eq(:open)
    end

    it "never confirms a bucket the count has merely entered" do
      expect(bucket.status_given(180)).to eq(:open)
      expect(bucket.status_given(190)).to eq(:open)
    end

    it "confirms a floor market once the count exceeds it" do
      expect(above.status_given(241)).to eq(:confirmed)
      expect(above.status_given(240)).to eq(:open)
    end

    it "never refutes a floor market early, however low the count" do
      expect(above.status_given(0)).to eq(:open)
    end

    # A count is already an integer. TempMarket rounds to whole degrees because
    # weather settles on a whole-degree report; rounding a count would move
    # every boundary by half a post.
    # TempMarket rounds to whole degrees because weather settles on a
    # whole-degree report. Rounding a count would move every boundary by half
    # a post: 199.4 would round to 199 and read as open, when the count has in
    # fact already passed the bucket.
    it "compares the count directly rather than rounding it" do
      expect(bucket.status_given(199.4)).to eq(:refuted)
      expect(bucket.status_given(199)).to eq(:open)
      expect(bucket.status_given(200)).to eq(:refuted)
    end

    it "settles nothing before the count is known" do
      expect(bucket.status_given(nil)).to eq(:open)
      expect(above.status_given(nil)).to eq(:open)
    end
  end

  describe "#settled_value_cents" do
    it "prices refuted at zero and confirmed at par" do
      expect(bucket.settled_value_cents(300)).to eq(0)
      expect(above.settled_value_cents(300)).to eq(100)
      expect(bucket.settled_value_cents(190)).to be_nil
    end
  end

  describe ".from_api" do
    it "reads strikes as integers, not floats" do
      m = described_class.from_api("ticker" => "T240", "strike_type" => "greater",
        "floor_strike" => 240, "cap_strike" => nil)

      expect(m.floor).to eq(240)
      expect(m.floor).to be_an(Integer)
    end

    it "ignores a strike type it cannot evaluate" do
      expect(described_class.from_api("ticker" => "X", "strike_type" => "custom")).to be_nil
    end
  end
end
