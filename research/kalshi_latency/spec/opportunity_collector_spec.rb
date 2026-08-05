require "tmpdir"
require "json"
require_relative "../lib/opportunity_collector"
require_relative "../lib/execution/pipeline"
require_relative "../lib/truth_scan"

FakeScan = Struct.new(:results) do
  def run = results
end

RSpec.describe OpportunityCollector do
  def weather_result(opportunities)
    WeatherScan::Result.new(city: "NYC", markets: 6, opportunities: opportunities)
  end

  it "records the truth-social family alongside weather and touch" do
    Dir.mktmpdir do |dir|
      truth_result = TruthScan::Result.new(
        series: "KXTRUTHSOCIAL", observed_count: 126, markets: 10,
        opportunities: [{ticker: "KXTRUTHSOCIAL-26AUG08-B109", side: :sell,
                         price_cents: 12, contracts: 25, net_cents: 281,
                         market_pct: 12, verified: true}]
      )
      collector = described_class.new(
        data_dir: dir,
        interval: 0,
        weather: FakeScan.new([]),
        touch: FakeScan.new([]),
        truth: FakeScan.new([truth_result]),
        logger: ->(m) {}
      )

      collector.run(seconds: 0.05)

      cycles = File.readlines(Dir[File.join(dir, "cycle-*.jsonl")].first).map { |l| JSON.parse(l) }
      truth_cycles = cycles.select { |c| c["family"] == "truth" }
      expect(truth_cycles).not_to be_empty
      expect(truth_cycles.first["opportunities"]).to eq(1)

      sightings = File.readlines(Dir[File.join(dir, "opportunity-*.jsonl")].first).map { |l| JSON.parse(l) }
      expect(sightings.first).to include("family" => "truth", "ticker" => "KXTRUTHSOCIAL-26AUG08-B109")
    end
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
