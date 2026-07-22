# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::FundingRateSnapshot do
  # Shapes below are verbatim from the live Advanced Trade products API
  # (2026-07-22): CDE perps leave perpetual_details empty and put funding at the
  # top level of future_product_details; INTX perps populate both.
  def cde_perp(product_id: "BIP-20DEC30-CDE", rate: "0.000021", funding_time: "2026-07-22T14:00:00Z")
    {
      "product_id" => product_id,
      "future_product_details" => {
        "contract_expiry_type" => "EXPIRING",
        "contract_expiry" => "2030-12-20T16:00:00Z",
        "perpetual_details" => {},
        "funding_interval" => "3600s",
        "funding_rate" => rate,
        "funding_time" => funding_time,
        "open_interest" => "220738"
      }
    }
  end

  def intx_perp(product_id: "BTC-PERP-INTX")
    {
      "product_id" => product_id,
      "future_product_details" => {
        "contract_expiry_type" => "PERPETUAL",
        "perpetual_details" => {
          "funding_rate" => "0.000004",
          "funding_time" => "2026-07-22T14:00:00.000024Z",
          "open_interest" => "1906.8019"
        },
        "funding_interval" => "3600s"
      }
    }
  end

  def dated_future(product_id: "BIT-31JUL26-CDE")
    {
      "product_id" => product_id,
      "future_product_details" => {
        "contract_expiry_type" => "EXPIRING",
        "contract_expiry" => "2026-07-31T16:00:00Z",
        "perpetual_details" => {},
        "open_interest" => "5312"
      }
    }
  end

  def rest_returning(products)
    instance_double(MarketData::CoinbaseRest, list_products: products)
  end

  it "snapshots CDE perps, whose funding fields sit outside perpetual_details" do
    described_class.call(rest: rest_returning([cde_perp]))

    record = FundingRate.find_by(product_id: "BIP-20DEC30-CDE")
    expect(record.funding_rate).to eq(BigDecimal("0.000021"))
    expect(record.funding_time).to eq(Time.utc(2026, 7, 22, 14, 0, 0))
    expect(record.funding_interval_seconds).to eq(3600)
    expect(record.open_interest).to eq(BigDecimal(220738))
    expect(record.observed_at).to be_present
  end

  it "snapshots INTX perps, which nest funding inside perpetual_details" do
    described_class.call(rest: rest_returning([intx_perp]))

    record = FundingRate.find_by(product_id: "BTC-PERP-INTX")
    expect(record.funding_rate).to eq(BigDecimal("0.000004"))
    expect(record.funding_interval_seconds).to eq(3600)
  end

  it "ignores dated futures, which carry no funding" do
    expect { described_class.call(rest: rest_returning([dated_future])) }
      .not_to change(FundingRate, :count)
  end

  it "returns the number of rows written" do
    expect(described_class.call(rest: rest_returning([cde_perp, intx_perp, dated_future]))).to eq(2)
  end

  describe "re-observing the same funding timestamp" do
    it "keeps one row and converges on the latest reading" do
      described_class.call(rest: rest_returning([cde_perp(rate: "0.000021")]))
      described_class.call(rest: rest_returning([cde_perp(rate: "0.000034")]))

      expect(FundingRate.for_product("BIP-20DEC30-CDE").count).to eq(1)
      expect(FundingRate.find_by(product_id: "BIP-20DEC30-CDE").funding_rate).to eq(BigDecimal("0.000034"))
    end

    it "keeps earlier funding timestamps as separate history" do
      described_class.call(rest: rest_returning([cde_perp(funding_time: "2026-07-22T14:00:00Z")]))
      described_class.call(rest: rest_returning([cde_perp(funding_time: "2026-07-22T15:00:00Z")]))

      expect(FundingRate.for_product("BIP-20DEC30-CDE").chronological.map(&:funding_time))
        .to eq([Time.utc(2026, 7, 22, 14), Time.utc(2026, 7, 22, 15)])
    end
  end

  describe "negative funding" do
    it "stores the sign, since shorts collect when longs are paid" do
      described_class.call(rest: rest_returning([cde_perp(rate: "-0.000015")]))

      expect(FundingRate.find_by(product_id: "BIP-20DEC30-CDE").funding_rate).to eq(BigDecimal("-0.000015"))
    end
  end

  describe "malformed API data" do
    it "skips a product with an unparseable funding interval rather than guessing" do
      product = cde_perp
      product["future_product_details"]["funding_interval"] = "hourly"

      expect { described_class.call(rest: rest_returning([product])) }
        .not_to change(FundingRate, :count)
    end

    it "skips a product whose funding_time is not a timestamp" do
      product = cde_perp
      product["future_product_details"]["funding_time"] = "not-a-time"

      expect { described_class.call(rest: rest_returning([product])) }
        .not_to change(FundingRate, :count)
    end

    it "does not blow up when the API returns no products" do
      expect { described_class.call(rest: rest_returning([])) }.not_to raise_error
    end
  end
end
