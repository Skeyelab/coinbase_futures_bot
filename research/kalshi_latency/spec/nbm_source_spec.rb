require "date"
require_relative "../lib/nbm_source"

RSpec.describe NbmSource do
  # IEM /api/1/mos.json rows: hourly valid times; only the 00Z-valid row of a
  # run carries txn/xnd for the daytime max. 00Z UTC Aug 6 is the evening of
  # Aug 5 in New York, so it covers Aug 5's daytime high.
  def rows
    [
      {"runtime_utc" => "2026-08-05T00:00:00", "ftime_utc" => "2026-08-05T12:00:00", "txn" => nil, "xnd" => nil},
      {"runtime_utc" => "2026-08-05T00:00:00", "ftime_utc" => "2026-08-06T00:00:00", "txn" => 82, "xnd" => 3},
      {"runtime_utc" => "2026-08-05T00:00:00", "ftime_utc" => "2026-08-07T00:00:00", "txn" => 84, "xnd" => 4}
    ]
  end

  def source
    described_class.new(fetch: ->(station) { rows })
  end

  it "returns the daytime-max forecast for a local date with its lead time" do
    forecast = source.forecast_for("KNYC", Date.new(2026, 8, 5), time_zone: "America/New_York")

    expect(forecast).to eq(txn: 82, xnd: 3, lead_hours: 24.0, runtime: "2026-08-05T00:00:00")
  end

  it "finds the later valid time for tomorrow" do
    forecast = source.forecast_for("KNYC", Date.new(2026, 8, 6), time_zone: "America/New_York")

    expect(forecast[:txn]).to eq(84)
    expect(forecast[:lead_hours]).to eq(48.0)
  end

  it "returns nil when no 00Z row covers the date" do
    forecast = source.forecast_for("KNYC", Date.new(2026, 8, 9), time_zone: "America/New_York")

    expect(forecast).to be_nil
  end
end
