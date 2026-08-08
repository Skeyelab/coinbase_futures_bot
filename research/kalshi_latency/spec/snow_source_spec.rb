require "date"
require_relative "../lib/snow_source"

RSpec.describe SnowSource do
  # IEM's CLI archive (json/cli.py) carries the same NWS Climatological Report
  # Kalshi settles temperature on. Snow arrives in three cumulative flavours:
  # `snow` (that day), `snow_month`, and `snow_jul1` (season to date, the
  # snow-season convention). Missing values arrive as the STRING "M", not nil.
  def rows
    [
      {"valid" => "2026-12-01", "snow" => 1.2, "snow_month" => 1.2, "snow_jul1" => 4.0},
      {"valid" => "2026-12-02", "snow" => 0.0, "snow_month" => 1.2, "snow_jul1" => 4.0},
      {"valid" => "2026-12-03", "snow" => 3.1, "snow_month" => 4.3, "snow_jul1" => 7.1},
      {"valid" => "2026-12-04", "snow" => "M", "snow_month" => "M", "snow_jul1" => "M"}
    ]
  end

  def source
    described_class.new(fetch: ->(_station, _year) { rows })
  end

  it "reports the season-to-date total, which can only rise" do
    expect(source.season_total("KBOS", as_of: Date.new(2026, 12, 3))).to eq(7.1)
  end

  it "carries the last known total forward through a missing report" do
    # "M" is not zero. Reading it as zero would make a cumulative total FALL,
    # which is the one thing a ratchet cannot do -- and would refute contracts
    # the season has already confirmed.
    expect(source.season_total("KBOS", as_of: Date.new(2026, 12, 4))).to eq(7.1)
  end

  it "ignores reports after the as-of date" do
    expect(source.season_total("KBOS", as_of: Date.new(2026, 12, 2))).to eq(4.0)
  end

  it "reports the month-to-date total too" do
    expect(source.month_total("KBOS", as_of: Date.new(2026, 12, 3))).to eq(4.3)
  end

  it "returns nil when no report covers the window rather than guessing zero" do
    expect(source.season_total("KBOS", as_of: Date.new(2026, 11, 1))).to be_nil
  end

  it "counts observations so a lone report can be doubted like any other" do
    expect(source.support("KBOS", as_of: Date.new(2026, 12, 3))).to eq(3)
  end

  it "constructs with its real HTTP fetcher" do
    expect { described_class.new }.not_to raise_error
  end
end
