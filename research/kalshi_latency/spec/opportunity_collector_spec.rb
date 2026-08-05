require "tmpdir"
require "json"
require_relative "../lib/opportunity_collector"
require_relative "../lib/execution/pipeline"

FakeScan = Struct.new(:results) do
  def run = results
end

RSpec.describe OpportunityCollector do
  def weather_result(opportunities)
    WeatherScan::Result.new(city: "NYC", markets: 6, opportunities: opportunities)
  end

  it "routes each weather sighting through the execution pipeline" do
    Dir.mktmpdir do |dir|
      sighting = {
        ticker: "KXHIGHNY-26AUG04-B83.5", side: :sell, price_cents: 3,
        contracts: 25, net_cents: 70, verified: true, market_pct: 3, peak_support: 5
      }
      collector = described_class.new(
        data_dir: dir,
        interval: 0,
        weather: FakeScan.new([weather_result([sighting])]),
        touch: FakeScan.new([]),
        execution: Execution::Pipeline.build(data_dir: dir),
        logger: ->(m) {}
      )

      collector.run(seconds: 0.05)

      orders = File.readlines(File.join(dir, "orders.jsonl")).map { |l| JSON.parse(l) }
      # Many cycles ran; the dedupe keeps it to one intent.
      expect(orders.size).to eq(1)
      expect(orders.first).to include("mode" => "dry_run", "ticker" => "KXHIGHNY-26AUG04-B83.5")
    end
  end
end
