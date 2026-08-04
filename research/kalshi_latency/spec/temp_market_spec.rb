require_relative "../lib/temp_market"

RSpec.describe TempMarket do
  # Kalshi's daily-high markets come in three shapes. A bucket ("83° to 84°"),
  # a floor ("89° or above"), and a ceiling ("80° or below").
  def bucket(floor: 83, cap: 84)
    described_class.new(ticker: "KXHIGHNY-26AUG04-B83.5", kind: :between, floor: floor, cap: cap)
  end

  def at_or_above(floor: 88)
    described_class.new(ticker: "KXHIGHNY-26AUG04-T88", kind: :greater, floor: floor, cap: nil)
  end

  def at_or_below(cap: 81)
    described_class.new(ticker: "KXHIGHNY-26AUG04-T81", kind: :less, floor: nil, cap: cap)
  end

  describe "#status_given" do
    it "leaves a bucket open while the day is still cooler than it" do
      expect(bucket.status_given(79)).to eq(:open)
    end

    it "kills a bucket once the day gets hotter than its top" do
      expect(bucket(floor: 83, cap: 84).status_given(85)).to eq(:refuted)
    end

    # The day can always keep warming, so landing inside a bucket settles
    # nothing. This is the case most likely to tempt a premature trade.
    it "will not confirm a bucket the day has merely reached" do
      expect(bucket(floor: 83, cap: 84).status_given(84)).to eq(:open)
    end

    it "confirms a floor the moment the day reaches it" do
      expect(at_or_above(floor: 88).status_given(88)).to eq(:confirmed)
    end

    it "leaves a floor open while the day is short of it" do
      expect(at_or_above(floor: 88).status_given(87)).to eq(:open)
    end

    it "kills a ceiling once the day rises past it" do
      expect(at_or_below(cap: 81).status_given(82)).to eq(:refuted)
    end

    it "leaves a ceiling open while the day is still under it" do
      expect(at_or_below(cap: 81).status_given(81)).to eq(:open)
    end

    # Kalshi settles on the NWS daily climate report, which publishes WHOLE
    # degrees. Comparing the raw observation instead of the degree it rounds to
    # invents edges that do not exist: 89.4F is a 89 degree day, and 89 sits
    # inside the 88-89 bucket rather than above it.
    it "settles on the whole degree the observation rounds to" do
      bucket_88_89 = described_class.new(ticker: "T", kind: :between, floor: 88, cap: 89)

      expect(bucket_88_89.status_given(89.4)).to eq(:open)
      expect(bucket_88_89.status_given(89.6)).to eq(:refuted)
    end

    it "rounds up to reach a floor market's strike" do
      expect(at_or_above(floor: 88).status_given(87.6)).to eq(:confirmed)
      expect(at_or_above(floor: 88).status_given(87.4)).to eq(:open)
    end

    # Before the day's first observation there is no running high at all.
    it "settles nothing when the day has not been observed yet" do
      expect(bucket.status_given(nil)).to eq(:open)
      expect(at_or_above.status_given(nil)).to eq(:open)
      expect(at_or_below.status_given(nil)).to eq(:open)
    end
  end

  describe "#settled_value_cents" do
    it "prices a refuted market at zero" do
      expect(bucket(floor: 83, cap: 84).settled_value_cents(85)).to eq(0)
    end

    it "prices a confirmed market at one hundred" do
      expect(at_or_above(floor: 88).settled_value_cents(90)).to eq(100)
    end

    it "refuses to price a market the day has not settled" do
      expect(bucket.settled_value_cents(79)).to be_nil
    end
  end
end
