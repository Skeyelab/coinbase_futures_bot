# frozen_string_literal: true

require "rails_helper"

RSpec.describe Cli::IndicatorsPresenter do
  def indicators(predictiveness:, protections:)
    {predictiveness: predictiveness, protections: protections}
  end

  it "renders a compact per-symbol 4h headline with maturity, and a protections line" do
    ind = indicators(
      predictiveness: {
        "computed_at" => "2026-07-24T00:00:00Z",
        "symbols" => [{
          "sentiment_symbol" => "OIL-USD", "price_symbol" => "NOL-19AUG26-CDE", "maturity" => "low",
          "horizons" => {"4" => {"correlation" => 0.1234, "hit_rate" => 0.55, "n" => 40, "signal_count" => 22}}
        }]
      },
      protections: {
        active: [{scope: "symbol", symbol: "NOL-19AUG26-CDE", source: "cooldown", side: "both", reason: "x", expires_at: "z"}],
        drawdown: {peak: 10_000.0, current: 9_680.0, drawdown_pct: 3.2}
      }
    )

    text = described_class.lines(ind).join("\n")

    expect(text).to match(/OIL-USD.*NOL-19AUG26-CDE/)
    expect(text).to match(/4h:.*r=0\.12/)
    expect(text).to match(/hit=55%/)
    expect(text).to match(/n=40/)
    expect(text).to match(/\[low\]/)
    expect(text).to match(/Protections:.*1 active.*cooldown/)
    expect(text).to match(/drawdown 3\.2%/)
  end

  it "shows 'not computed yet' when predictiveness has no symbols" do
    ind = indicators(predictiveness: {"computed_at" => nil, "symbols" => []},
      protections: {active: [], drawdown: {peak: nil, current: nil, drawdown_pct: nil}})

    text = described_class.lines(ind).join("\n")

    expect(text).to match(/not computed yet/)
    expect(text).to match(/Protections:.*none/)
  end

  it "renders n/a rather than a fake number when a horizon has no data" do
    ind = indicators(
      predictiveness: {"computed_at" => "t", "symbols" => [{
        "sentiment_symbol" => "BTC-USD", "price_symbol" => "BTC-USD", "maturity" => "low",
        "horizons" => {"4" => {"correlation" => nil, "hit_rate" => nil, "n" => 3, "signal_count" => 0}}
      }]},
      protections: {active: [], drawdown: {drawdown_pct: nil}}
    )

    text = described_class.lines(ind).join("\n")
    expect(text).to match(/r=n\/a hit=n\/a/)
  end
end
