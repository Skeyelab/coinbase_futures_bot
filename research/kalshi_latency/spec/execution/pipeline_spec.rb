require "tmpdir"
require "json"
require_relative "../../lib/execution/pipeline"
require_relative "../../lib/execution/loss_stop"
require_relative "../../lib/execution/halt"

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
      # market_pct 40 == the book disputes us, which is where persistence
      # still applies after the 2026-08-07 conditioning.
      disputed = sighting(market_pct: 40)
      pipeline.sight(disputed.merge(verified: false), at: 1000)
      pipeline.sight(disputed.merge(verified: false), at: 1200)
      late = pipeline.sight(disputed, at: 1400)

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

  it "exits a repriced position through check_exits" do
    Dir.mktmpdir do |dir|
      reader = double("reader", quotes: [{ticker: "KXHIGHNY-26AUG04-B83.5", bid_cents: 1, ask_cents: 2}])
      pipeline = described_class.build(data_dir: dir, reader: reader)

      pipeline.sight(sighting, at: 1000) # places the entry (sell at 3c... entry recorded)
      exits = pipeline.check_exits

      expect(exits.size).to eq(1)
      refreshed = File.readlines(File.join(dir, "orders.jsonl")).map { |l| JSON.parse(l) }
      expect(refreshed.last["exit"]).to be(true)
    end
  end

  it "check_exits is a no-op without a reader (pure dry-run pipelines)" do
    Dir.mktmpdir do |dir|
      pipeline = described_class.build(data_dir: dir)
      pipeline.sight(sighting, at: 1000)

      expect(pipeline.check_exits).to eq([])
    end
  end

  it "places nothing once the daily loss stop has engaged" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      stop = Execution::LossStop.new(client: double("client"), halt: halt,
        data_dir: dir, budget_cents: 1000)
      stop.mark_open(25_000)
      stop.check(balance_cents: 23_000) # -$20: breached, halt engaged
      pipeline = described_class.build(data_dir: dir)

      expect(pipeline.sight(sighting, at: 1000)).to be_nil
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
