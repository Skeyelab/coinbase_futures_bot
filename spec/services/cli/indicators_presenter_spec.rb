# frozen_string_literal: true

require "rails_helper"

RSpec.describe Cli::IndicatorsPresenter do
  def indicators(predictiveness:, protections:, exits: nil, sentiment: nil, strategy: nil)
    {predictiveness: predictiveness, protections: protections, exits: exits, sentiment: sentiment, strategy: strategy}
  end

  it "renders a strategy line per symbol: trend, rsi, macd sign; insufficient flagged (#447)" do
    ind = indicators(
      predictiveness: {"symbols" => []}, protections: {active: [], drawdown: {}},
      strategy: {symbols: [
        {sentiment_symbol: "OIL-USD", price_symbol: "NOL", strategy_trend: "up", rsi: 58.0, macd_histogram: 0.4, insufficient: false},
        {sentiment_symbol: "ETH-USD", price_symbol: "ETH-USD", insufficient: true}
      ]}
    )

    text = described_class.lines(ind).join("\n")
    expect(text).to match(/Strategy:/)
    expect(text).to match(/OIL-USD trend=up rsi=58/)
    expect(text).to match(/macd=\+/)
    expect(text).to match(/ETH-USD: insufficient data/)
  end

  it "renders a sentiment line per symbol: z, trend arrow, inflow, undersampled flag (#446)" do
    ind = indicators(
      predictiveness: {"symbols" => []}, protections: {active: [], drawdown: {}},
      sentiment: {symbols: [
        {symbol: "OIL-USD", z: 1.5, trend: [0.5, 1.0, 1.5], inflow_per_hr: 2, undersampled: true}
      ]}
    )

    text = described_class.lines(ind).join("\n")
    expect(text).to match(/Sentiment:/)
    expect(text).to match(/OIL-USD z=1\.5/)
    expect(text).to match(/↑/) # rising trend
    expect(text).to match(/\(2\/hr\)/)
    expect(text).to match(/undersampled/)
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

  it "renders an exits line: global dollar exit + per-symbol liq/min-roi counts (#448)" do
    ind = indicators(
      predictiveness: {"symbols" => []},
      protections: {active: [], drawdown: {}},
      exits: {
        dollar_exit: {enabled: true, profit_target: 50.0, stop_loss: nil},
        symbols: [
          {symbol: "NOL-19AUG26-CDE", min_roi: {enabled: false, rungs: []}, liquidation_buffer: {enabled: true, buffer: 0.05}},
          {symbol: "BIT-25SEP26-CDE", min_roi: {enabled: false, rungs: []}, liquidation_buffer: {enabled: true, buffer: 0.05}}
        ]
      }
    )

    text = described_class.lines(ind).join("\n")
    expect(text).to match(/Exits:/)
    expect(text).to match(/dollar tgt=\$50/)
    expect(text).to match(/liq-buffer 2\/2/)
    expect(text).to match(/min-roi 0\/2/)
  end
end
