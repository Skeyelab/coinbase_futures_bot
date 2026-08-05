require "tmpdir"
require "json"
require_relative "../../lib/execution/pipeline"

RSpec.describe Execution::Pipeline do
  def sighting(over = {})
    {
      ticker: "KXHIGHNY-26AUG04-B83.5",
      side: :sell,
      price_cents: 3,
      contracts: 25,
      net_cents: 70,
      verified: true,
      market_pct: 3,
      peak_support: 5
    }.merge(over)
  end

  it "turns a fresh credible sighting into a dry-run intent on disk" do
    Dir.mktmpdir do |dir|
      pipeline = described_class.build(data_dir: dir)

      intent = pipeline.sight(sighting, at: 1000)

      expect(intent[:mode]).to eq("dry_run")
      logged = JSON.parse(File.read(File.join(dir, "orders.jsonl")))
      expect(logged["ticker"]).to eq("KXHIGHNY-26AUG04-B83.5")
    end
  end

  it "feeds the episode's own dwell into the persistence doubt" do
    Dir.mktmpdir do |dir|
      pipeline = described_class.build(data_dir: dir)

      # An unverified-station sighting is refused but keeps its episode clock
      # running. By the time it looks credible it has persisted past the
      # threshold -- the pipeline must know that and refuse.
      pipeline.sight(sighting(verified: false), at: 1000)
      pipeline.sight(sighting(verified: false), at: 1200)
      late = pipeline.sight(sighting, at: 1400)

      expect(late).to be_nil
      refusals = File.readlines(File.join(dir, "orders.jsonl")).map { |l| JSON.parse(l) }
      expect(refusals.last["doubts"]).to include("persisted 400s")
    end
  end

  it "carries peak support into the lone-spike doubt" do
    Dir.mktmpdir do |dir|
      pipeline = described_class.build(data_dir: dir)

      intent = pipeline.sight(sighting(peak_support: 1), at: 1000)

      expect(intent).to be_nil
      refusal = JSON.parse(File.read(File.join(dir, "orders.jsonl")))
      expect(refusal["doubts"]).to include("lone spike (1 obs)")
    end
  end

  it "carries the market's own price into the disagreement doubt" do
    Dir.mktmpdir do |dir|
      pipeline = described_class.build(data_dir: dir)

      intent = pipeline.sight(sighting(market_pct: 99), at: 1000)

      expect(intent).to be_nil
      refusal = JSON.parse(File.read(File.join(dir, "orders.jsonl")))
      expect(refusal["doubts"]).to include("market disagrees 99%")
    end
  end

  it "honors a HALT file in the data directory" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "HALT"), "ops")
      pipeline = described_class.build(data_dir: dir)

      expect(pipeline.sight(sighting, at: 1000)).to be_nil
    end
  end

  it "refuses unverified stations even when everything else looks right" do
    Dir.mktmpdir do |dir|
      pipeline = described_class.build(data_dir: dir)

      intent = pipeline.sight(sighting(verified: false), at: 1000)

      expect(intent).to be_nil
    end
  end
end
