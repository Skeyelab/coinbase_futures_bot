require_relative "../lib/touch_market"

RSpec.describe TouchMarket do
  # KXBTCMINMON-BTC-26AUG31-600000  "Below $60,000.00"
  def below(threshold: 60_000.0)
    described_class.new(ticker: "KXBTCMINMON-BTC-26AUG31-600000", direction: :below, threshold: threshold)
  end

  # KXBTCMAXY-26DEC31-99999.99  "Above $99,999.99"
  def above(threshold: 99_999.99)
    described_class.new(ticker: "KXBTCMAXY-26DEC31-99999.99", direction: :above, threshold: threshold)
  end

  describe "#status_given" do
    it "confirms a below-touch once the running minimum has gone under it" do
      expect(below.status_given(59_900.0)).to eq(:confirmed)
    end

    it "leaves a below-touch open while the minimum is still above the level" do
      expect(below.status_given(60_100.0)).to eq(:open)
    end

    it "confirms an above-touch once the running maximum has cleared it" do
      expect(above.status_given(100_500.0)).to eq(:confirmed)
      expect(above.status_given(99_000.0)).to eq(:open)
    end

    # THE ASYMMETRY, and the opposite of a temperature bucket's. Remaining time
    # can always deliver the touch, so an untouched contract is never worth
    # zero -- it is merely unlikely. Refuting one early would be selling
    # something that can still come true.
    it "never refutes a one-touch, however far away the level is" do
      expect(below.status_given(90_000.0)).to eq(:open)
      expect(above.status_given(10.0)).to eq(:open)
      expect(below.status_given(90_000.0)).not_to eq(:refuted)
    end

    # Kalshi writes the strike to sit clear of the round number ("Above
    # $99,999.99"), so the boundary is already in the figure.
    it "requires the level to actually be passed, not merely equalled" do
      expect(above(threshold: 100_000.0).status_given(100_000.0)).to eq(:open)
      expect(below(threshold: 60_000.0).status_given(60_000.0)).to eq(:open)
    end

    it "holds when the extreme is unknown" do
      expect(below.status_given(nil)).to eq(:open)
      expect(described_class.new(ticker: "T", direction: :below, threshold: nil)
        .status_given(1.0)).to eq(:open)
    end
  end

  describe "construction" do
    it "refuses a direction it cannot evaluate" do
      expect { described_class.new(ticker: "T", direction: :sideways, threshold: 1.0) }
        .to raise_error(ArgumentError, /sideways/)
    end
  end

  # Both ratchet markets answer the same question, which is what lets
  # Opportunity price either without knowing which it holds.
  describe "the shared ratchet contract" do
    it "answers status_given like a temperature market does" do
      expect(below).to respond_to(:status_given)
      expect(below.status_given(59_000.0)).to be_a(Symbol)
      expect(below).to respond_to(:ticker)
    end
  end
end
