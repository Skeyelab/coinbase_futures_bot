# frozen_string_literal: true

require "rails_helper"

# Issue #374/#377. Perps charge 0% maker against ~3 bps taker, so entering as a
# maker removes roughly 40% of the round-trip cost — the largest cost reduction
# available, and an execution change rather than a prediction problem. ADR 0002's
# +15 -> +22 bps upgrade rests entirely on it.
#
# The hazard is the opposite of the benefit: a post-only order that does not fill
# leaves no position, and a GTC one sits on the book indefinitely. So maker
# entries are good-till-DATE — the exchange expires them — and the caller learns
# whether it filled rather than assuming it did.
RSpec.describe Trading::CoinbasePositions, "maker entries" do
  subject(:service) { described_class.new(logger: Logger.new(IO::NULL)) }

  def body(type:, price: nil, **opts)
    service.send(:build_order_body, product_id: "BIP-20DEC30-CDE", side: :long,
      size: 1, type: type, price: price, **opts)
  end

  describe "order construction" do
    it "still builds an IOC market order by default" do
      expect(body(type: :market)["order_configuration"]).to have_key("market_market_ioc")
    end

    # post_only is what makes it a maker order at all: the exchange rejects it
    # rather than crossing the spread, so it can never silently pay taker.
    it "builds a post-only, time-bounded limit order for a maker entry" do
      config = body(type: :maker, price: 64_000.0)["order_configuration"]
      gtd = config["limit_limit_gtd"]

      expect(gtd).to be_present
      expect(gtd["post_only"]).to be true
      expect(gtd["limit_price"]).to eq("64000.0")
      expect(Time.parse(gtd["end_time"])).to be > Time.current
    end

    it "expires a maker entry within the configured window" do
      ClimateControl.modify(MAKER_ORDER_TTL_SECONDS: "45") do
        gtd = body(type: :maker, price: 64_000.0)["order_configuration"]["limit_limit_gtd"]
        expect(Time.parse(gtd["end_time"])).to be_within(5.seconds).of(45.seconds.from_now)
      end
    end

    it "refuses a maker entry with no price — it cannot rest on the book" do
      expect { body(type: :maker) }.to raise_error(ArgumentError, /price is required/)
    end

    # A plain :limit stays taker-eligible; only :maker asserts post_only. Keeping
    # them distinct means an existing caller cannot silently become a maker.
    it "leaves the existing limit type taker-eligible" do
      gtc = body(type: :limit, price: 64_000.0)["order_configuration"]["limit_limit_gtc"]
      expect(gtc["post_only"]).to be false
    end
  end

  describe "entry order type resolution" do
    it "defaults to market so behaviour is unchanged until deliberately switched" do
      expect(described_class.entry_order_type).to eq(:market)
    end

    it "honours the configured maker preference" do
      ClimateControl.modify(ENTRY_ORDER_TYPE: "maker") do
        expect(described_class.entry_order_type).to eq(:maker)
      end
    end

    # Only perps are 0% maker. Asking for a maker entry on a dated contract buys
    # nothing (both sides ~9 bps) and risks not filling, so it degrades to market.
    it "degrades to market on a venue with no maker discount" do
      ClimateControl.modify(ENTRY_ORDER_TYPE: "maker") do
        expect(described_class.entry_order_type(symbol: "NOL-19AUG26-CDE")).to eq(:market)
      end
    end

    it "keeps maker for a perp" do
      FundingRate.create!(product_id: "BIP-TEST", funding_time: 1.hour.ago, funding_rate: 0.000013,
        funding_interval_seconds: 3600, observed_at: 1.hour.ago)

      ClimateControl.modify(ENTRY_ORDER_TYPE: "maker") do
        expect(described_class.entry_order_type(symbol: "BIP-TEST")).to eq(:maker)
      end
    end
  end

  describe "passive pricing" do
    # A momentum entry fires exactly when price is moving toward it, so posting
    # at the signal price would mostly be rejected for crossing. Resting below
    # (buy) or above (sell) is what makes it a maker order in practice.
    it "posts below the market to buy" do
      expect(described_class.maker_price(64_000.0, :long)).to be < 64_000.0
    end

    it "posts above the market to sell" do
      expect(described_class.maker_price(64_000.0, :short)).to be > 64_000.0
    end

    it "uses the configured offset" do
      ClimateControl.modify(MAKER_PRICE_OFFSET_BPS: "10") do
        expect(described_class.maker_price(1_000.0, :long)).to be_within(1e-6).of(999.0)
        expect(described_class.maker_price(1_000.0, :short)).to be_within(1e-6).of(1_001.0)
      end
    end
  end
end
