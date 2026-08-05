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

    # THE BOUNDARY. Kalshi's floor_strike on a `greater` market is EXCLUSIVE:
    # KXHIGHPHIL-26AUG04-T90 carries floor_strike=90 and reads "91 or above".
    # Treating the floor as inclusive confirmed a contract at 90 that actually
    # needs 91, and the scanner reported $23 of free money that did not exist.
    it "needs the day to clear a floor market's strike, not merely reach it" do
      expect(at_or_above(floor: 88).status_given(88)).to eq(:open)
      expect(at_or_above(floor: 88).status_given(89)).to eq(:confirmed)
    end

    it "leaves a floor open well short of it" do
      expect(at_or_above(floor: 88).status_given(87)).to eq(:open)
    end

    # Symmetrically, cap_strike on a `less` market is EXCLUSIVE:
    # KXHIGHPHIL-26AUG04-T83 carries cap_strike=83 and reads "82 or below".
    # So landing ON the cap refutes it.
    it "kills a ceiling as soon as the day reaches its strike" do
      expect(at_or_below(cap: 81).status_given(81)).to eq(:refuted)
      expect(at_or_below(cap: 81).status_given(82)).to eq(:refuted)
    end

    it "leaves a ceiling open while the day is genuinely under it" do
      expect(at_or_below(cap: 81).status_given(80)).to eq(:open)
    end

    # Buckets are the exception: floor and cap are both INCLUSIVE.
    # KXHIGHPHIL-26AUG04-B89.5 is floor=89 cap=90 and reads "89 to 90".
    it "treats a bucket's own bounds as inclusive" do
      b = described_class.new(ticker: "T", kind: :between, floor: 89, cap: 90)

      expect(b.status_given(89)).to eq(:open)
      expect(b.status_given(90)).to eq(:open)
      expect(b.status_given(91)).to eq(:refuted)
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

    # Rounding and the exclusive floor compose: 88.6 settles as 89, which
    # clears a floor of 88; 87.6 settles as 88, which only REACHES it.
    it "rounds first, then requires the rounded degree to clear the floor" do
      expect(at_or_above(floor: 88).status_given(88.6)).to eq(:confirmed)
      expect(at_or_above(floor: 88).status_given(87.6)).to eq(:open)
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
  # What an :open contract settles as once the day is OVER. A daily high can
  # only rise, so :open means it never got there -- which resolves a "reach
  # this level" contract NO and a "stay below this level" contract YES. One
  # blanket answer is wrong for half the board.
  describe "#settles_open_as" do
    it "confirms a less market, because the high never exceeded the cap" do
      market = described_class.new(ticker: "KXHIGHTSEA-26AUG04-T84", kind: :less, floor: nil, cap: 84)

      expect(market.settles_open_as).to eq(:confirmed)
    end

    it "refutes a greater market, because the high never reached the floor" do
      market = described_class.new(ticker: "KXHIGHTSEA-26AUG04-T91", kind: :greater, floor: 91, cap: nil)

      expect(market.settles_open_as).to eq(:refuted)
    end

    it "refutes a between market, because the high never reached the band" do
      market = described_class.new(ticker: "KXHIGHTSEA-26AUG04-B84.5", kind: :between, floor: 84, cap: 85)

      expect(market.settles_open_as).to eq(:refuted)
    end
  end
end
