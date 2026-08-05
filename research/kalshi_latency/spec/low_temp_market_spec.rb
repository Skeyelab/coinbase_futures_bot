require_relative "../lib/low_temp_market"

RSpec.describe LowTempMarket do
  # Verified against live KXLOWTPHIL-26AUG05 markets and their rules text:
  #   B70.5  between floor=70 cap=71  "70 to 71"
  #   T71    greater floor=71         "72 or above"  -> YES iff min > 71
  #   T64    less    cap=64           "63 or below"  -> YES iff min < 64
  def bucket = described_class.new(ticker: "B", kind: :between, floor: 70, cap: 71)
  def above = described_class.new(ticker: "G", kind: :greater, floor: 71, cap: nil)
  def below = described_class.new(ticker: "L", kind: :less, floor: nil, cap: 64)

  describe "#status_given" do
    # A minimum only falls, so dropping under a bucket kills it permanently.
    it "kills a bucket once the night gets colder than it" do
      expect(bucket.status_given(69)).to eq(:refuted)
      expect(bucket.status_given(70)).to eq(:open)
    end

    it "never confirms a bucket the night has merely reached" do
      expect(bucket.status_given(71)).to eq(:open)
      expect(bucket.status_given(70)).to eq(:open)
    end

    # THE SWAP. On a HIGH market a floor contract is confirmable early. On a
    # LOW market it is REFUTABLE early -- reaching the strike kills it, because
    # the minimum can never climb back.
    it "kills a floor contract once the night reaches its strike" do
      expect(above.status_given(71)).to eq(:refuted)
      expect(above.status_given(70)).to eq(:refuted)
      expect(above.status_given(72)).to eq(:open)
    end

    it "never confirms a floor contract early, however warm the night" do
      expect(above.status_given(95)).to eq(:open)
    end

    it "confirms a ceiling contract once the night drops under it" do
      expect(below.status_given(63)).to eq(:confirmed)
      expect(below.status_given(64)).to eq(:open)
    end

    it "never refutes a ceiling contract early" do
      expect(below.status_given(90)).to eq(:open)
    end

    it "settles on the whole degree the reading rounds to" do
      expect(bucket.status_given(69.6)).to eq(:open)     # rounds to 70, inside
      expect(bucket.status_given(69.4)).to eq(:refuted)  # rounds to 69, below
    end

    it "settles nothing before the night has been observed" do
      expect(bucket.status_given(nil)).to eq(:open)
      expect(above.status_given(nil)).to eq(:open)
      expect(below.status_given(nil)).to eq(:open)
    end
  end

  describe "#settled_value_cents" do
    it "prices a refuted contract at zero and a confirmed one at par" do
      expect(bucket.settled_value_cents(60)).to eq(0)
      expect(below.settled_value_cents(60)).to eq(100)
      expect(bucket.settled_value_cents(70)).to be_nil
    end
  end
  # The mirror of TempMarket, and the side that flips. A daily MINIMUM can only
  # fall, so :open at end of day means it never fell that far -- which confirms
  # a "stay above this level" contract and refutes the rest. Copying the high
  # rule across without inverting produces a model that is confidently backwards.
  describe "#settles_open_as" do
    it "confirms a greater market, because the min never fell to the floor" do
      market = described_class.new(ticker: "KXLOWTDEN-26AUG04-T52", kind: :greater, floor: 52, cap: nil)

      expect(market.settles_open_as).to eq(:confirmed)
    end

    it "refutes a less market, because the min never fell to the cap" do
      market = described_class.new(ticker: "KXLOWTDEN-26AUG04-T48", kind: :less, floor: nil, cap: 48)

      expect(market.settles_open_as).to eq(:refuted)
    end

    it "refutes a between market, because the min never reached the band" do
      market = described_class.new(ticker: "KXLOWTDEN-26AUG04-B50.5", kind: :between, floor: 50, cap: 51)

      expect(market.settles_open_as).to eq(:refuted)
    end
  end
end
