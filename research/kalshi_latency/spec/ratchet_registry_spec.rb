require_relative "../lib/ratchet_registry"

RSpec.describe RatchetRegistry do
  # strike_type is NOT enough to know what a market means:
  #
  #   KXHIGHNY-...-T81      strike_type=less cap=81     "80 or below"
  #                         -> the day's HIGH must stay under the cap
  #   KXBTCMINMON-...       strike_type=less cap=60000  "Below $60,000"
  #                         -> the running MINIMUM ever went under it
  #
  # Identical strike_type, opposite observables. Dispatching on it alone would
  # read the one-touch exactly backwards.
  def temp_ceiling
    {"ticker" => "KXHIGHNY-26AUG04-T81", "strike_type" => "less",
     "floor_strike" => nil, "cap_strike" => 81}
  end

  def btc_touch
    {"ticker" => "KXBTCMINMON-BTC-26AUG31-6000000", "strike_type" => "less",
     "floor_strike" => nil, "cap_strike" => 60_000}
  end

  describe ".build" do
    it "reads a temperature ceiling as a temperature market" do
      market = described_class.build(temp_ceiling)

      expect(market).to be_a(TempMarket)
      expect(market.status_given(82)).to eq(:refuted)
    end

    # The whole point. Same strike_type, opposite reading.
    it "reads a one-touch as a one-touch despite the identical strike_type" do
      market = described_class.build(btc_touch)

      expect(market).to be_a(TouchMarket)
      expect(market.direction).to eq(:below)
      expect(market.threshold).to eq(60_000.0)
      # A minimum under the level CONFIRMS. TempMarket would have called a
      # value over the cap REFUTED, which is backwards for this series.
      expect(market.status_given(59_000.0)).to eq(:confirmed)
      expect(market.status_given(61_000.0)).to eq(:open)
    end

    it "builds an above-touch off the floor strike" do
      market = described_class.build({"ticker" => "KXBTCMAXY-26DEC31-99999.99",
        "strike_type" => "greater", "floor_strike" => 99_999.99, "cap_strike" => nil})

      expect(market.direction).to eq(:above)
      expect(market.status_given(100_500.0)).to eq(:confirmed)
    end

    # Silence beats a guess. Kalshi has 12,460 series and we have read the
    # rules of five; the rest must not be priced by inference.
    it "returns nothing for a series whose rules nobody has read" do
      expect(described_class.build({"ticker" => "KXNBAMVP-27-AEDWARDS5",
        "strike_type" => "greater", "floor_strike" => 1, "cap_strike" => nil})).to be_nil
    end

    it "returns nothing when the strike it needs is missing" do
      expect(described_class.build({"ticker" => "KXBTCMINMON-BTC-26AUG31-6000000",
        "strike_type" => "less", "floor_strike" => nil, "cap_strike" => nil})).to be_nil
    end

    # A cumulative count is the same ratchet as a daily maximum, and the
    # registry has to know that BEFORE strike_type is consulted -- KXTRUTHSOCIAL
    # uses "between" and "greater" exactly like a temperature series, but the
    # observable is a post count that must not be rounded.
    it "reads a post-count market as a count market" do
      market = described_class.build({"ticker" => "KXTRUTHSOCIAL-26AUG08-B189",
        "strike_type" => "between", "floor_strike" => 180, "cap_strike" => 199})

      expect(market).to be_a(CountMarket)
      expect(market.status_given(200)).to eq(:refuted)
      expect(market.status_given(199)).to eq(:open)
    end
  end

  describe ".observable_for" do
    it "names the running extreme each series ratchets on" do
      expect(described_class.observable_for("KXHIGHAUS-26AUG04-B97.5")).to eq(:daily_high_f)
      expect(described_class.observable_for("KXBTCMINMON-BTC-26AUG31-6000000")).to eq(:window_min_usd)
      expect(described_class.observable_for("KXBTCMAXY-26DEC31-99999.99")).to eq(:window_max_usd)
      expect(described_class.observable_for("KXTRUTHSOCIAL-26AUG08-B189")).to eq(:week_post_count)
    end

    # Prefix, not substring. A series that merely CONTAINS a registered name
    # is a different market with different rules, and matching it would price
    # something nobody has read.
    it "matches the series prefix, not any occurrence of it" do
      expect(described_class.observable_for("KXNOTKXHIGHTEMP-26AUG04-B90")).to be_nil
      expect(described_class.build({"ticker" => "SOMETHINGKXBTCMINMON-1",
        "strike_type" => "less", "floor_strike" => nil, "cap_strike" => 60_000})).to be_nil
    end

    it "has no observable for an unregistered series" do
      expect(described_class.observable_for("KXNBAMVP-27-AEDWARDS5")).to be_nil
    end
  end

  # Built 2026-08-07, BEFORE the snow markets list (August). KXNAMEDSTORM and
  # KXHURRICANE are already open; snow appears in season. Registering them now
  # means the scan picks each up the day it lists rather than after.
  describe "cumulative-count families beyond Truth Social" do
    it "reads a named-storm season total as a count ratchet" do
      row = {"ticker" => "KXNAMEDSTORM-26DEC01EPACTOT-26", "strike_type" => "greater",
             "floor_strike" => 26, "cap_strike" => nil}

      market = described_class.build(row)

      expect(market).to be_a(CountMarket)
      expect(described_class.observable_for(row["ticker"])).to eq(:season_named_storms)
      # A season total can only rise, so exceeding the floor CONFIRMS.
      expect(market.status_given(27)).to eq(:confirmed)
      expect(market.status_given(20)).to eq(:open)
    end

    it "reads a hurricane count the same way" do
      row = {"ticker" => "KXHURRICANE-26JUN30CPACMAJ-9", "strike_type" => "greater",
             "floor_strike" => 9, "cap_strike" => nil}

      expect(described_class.build(row)).to be_a(CountMarket)
      expect(described_class.observable_for(row["ticker"])).to eq(:season_hurricanes)
    end

    it "reads a seasonal snowfall total as a count ratchet" do
      row = {"ticker" => "KXSNOWBOS-27JUN30-T40", "strike_type" => "greater",
             "floor_strike" => 40, "cap_strike" => nil}

      expect(described_class.build(row)).to be_a(CountMarket)
      expect(described_class.observable_for(row["ticker"])).to eq(:season_snow_inches)
    end

    it "still refuses a series whose rules nobody has read" do
      expect(described_class.build({"ticker" => "KXMYSTERY-26DEC01-5"})).to be_nil
    end
  end
end
