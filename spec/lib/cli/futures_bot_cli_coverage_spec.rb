# frozen_string_literal: true

require "rails_helper"
require "cli/futures_bot_cli"

# Issue #506: 1m depth was invisible from every operator surface, so five
# contracts sat unable to emit a signal without anything reporting it.
RSpec.describe Cli::FuturesBotCli, "coverage command (issue #506)" do
  def contract(product_id, deep_at: nil)
    Contract.find_or_create_by(product_id: product_id) do |c|
      c.base_currency = "BTC"
      c.quote_currency = "USD"
      c.status = "active"
      c.expiration_date = Date.current + 60
    end.tap { |c| c.update!(enabled: true, deep_1m_backfilled_at: deep_at) }
  end

  def candles!(product_id, timeframe, count)
    base = 10.days.ago.change(sec: 0)
    count.times do |i|
      Candle.find_or_create_by!(symbol: product_id, timeframe: timeframe, timestamp: base + i.minutes) do |c|
        c.open = 1
        c.high = 1
        c.low = 1
        c.close = 1
        c.volume = 1
      end
    end
  end

  def run_json
    JSON.parse(capture_stdout { described_class.new.invoke(:coverage, [], json: true) })
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  before { Contract.update_all(enabled: false) }

  it "reports a starved contract as unable to emit a signal" do
    starved = contract("BIT-30OCT26-CDE")
    candles!(starved.product_id, "1m", 5)

    row = run_json["contracts"].find { |r| r["product_id"] == starved.product_id }

    expect(row["candles"]["1m"]).to eq(5)
    expect(row["signal_capable"]).to be(false)
    expect(row["deep_1m_backfilled_at"]).to be_nil
  end

  it "reports a contract with enough 1m as signal-capable" do
    deep = contract("BIT-31JUL26-CDE", deep_at: 1.day.ago)
    candles!(deep.product_id, "1m", Cli::FuturesBotCli::MIN_1M_FOR_SIGNAL + 1)

    row = run_json["contracts"].find { |r| r["product_id"] == deep.product_id }

    expect(row["signal_capable"]).to be(true)
    expect(row["deep_1m_backfilled_at"]).not_to be_nil
  end

  it "publishes the threshold it judges against, read from the strategy" do
    contract("BIT-30OCT26-CDE")

    expect(run_json["min_1m_for_signal"])
      .to eq(Strategy::MultiTimeframeSignal::DEFAULTS[:min_1m_candles])
  end

  it "distinguishes 1m starvation from the timeframes that look healthy" do
    starved = contract("ET-30OCT26-CDE")
    candles!(starved.product_id, "1m", 2)
    candles!(starved.product_id, "5m", 900)
    candles!(starved.product_id, "1h", 400)

    row = run_json["contracts"].find { |r| r["product_id"] == starved.product_id }

    # The exact shape of the #506 trap: healthy elsewhere, unusable on 1m.
    expect(row["candles"]["5m"]).to be > 500
    expect(row["candles"]["1h"]).to be > 100
    expect(row["signal_capable"]).to be(false)
  end
end
