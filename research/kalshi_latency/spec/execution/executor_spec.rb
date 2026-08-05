require "tmpdir"
require "json"
require_relative "../../lib/execution/executor"
require_relative "../../lib/execution/order_client"
require_relative "../../lib/execution/order_log"

RSpec.describe Execution::Executor do
  def opportunity(over = {})
    {
      ticker: "KXHIGHNY-26AUG04-B83.5",
      side: :sell,
      price_cents: 12,
      contracts: 25,
      net_cents: 281
    }.merge(over)
  end

  def build(dir)
    client = Execution::OrderClient.new(transport: ->(*) { raise "no network" })
    log = Execution::OrderLog.new(path: File.join(dir, "orders.jsonl"))
    described_class.new(client: client, log: log)
  end

  it "places once per ticker however long the episode persists" do
    Dir.mktmpdir do |dir|
      executor = build(dir)
      episode = {market_pct: 2, support: 5, seconds: 30}

      first = executor.consider(opportunity, episode: episode)
      second = executor.consider(opportunity, episode: episode)

      expect(first).not_to be_nil
      expect(second).to be_nil
      lines = File.readlines(File.join(dir, "orders.jsonl"))
      expect(lines.size).to eq(1)
    end
  end

  it "logs a refusal only when the doubts change, not every scan cycle" do
    Dir.mktmpdir do |dir|
      executor = build(dir)

      executor.consider(opportunity, episode: {market_pct: 99, support: 1, seconds: 100})
      executor.consider(opportunity, episode: {market_pct: 99, support: 1, seconds: 160})
      # support arrives; the doubt set shrinks -> worth a new line
      executor.consider(opportunity, episode: {market_pct: 99, support: 5, seconds: 220})

      lines = File.readlines(File.join(dir, "orders.jsonl")).map { |l| JSON.parse(l) }
      expect(lines.size).to eq(2)
      expect(lines[0]["doubts"]).to include("lone spike (1 obs)")
      expect(lines[1]["doubts"]).not_to include("lone spike (1 obs)")
    end
  end

  it "does not treat a growing persistence counter as a new doubt" do
    Dir.mktmpdir do |dir|
      executor = build(dir)

      # Same doubt KIND every cycle; only the seconds tick up. LAX sat for
      # 19,000s -- that must be one line, not three hundred.
      executor.consider(opportunity, episode: {market_pct: 2, support: 5, seconds: 400})
      executor.consider(opportunity, episode: {market_pct: 2, support: 5, seconds: 460})
      executor.consider(opportunity, episode: {market_pct: 2, support: 5, seconds: 520})

      lines = File.readlines(File.join(dir, "orders.jsonl"))
      expect(lines.size).to eq(1)
    end
  end

  it "can still place after a refusal once the doubts clear" do
    Dir.mktmpdir do |dir|
      executor = build(dir)

      refused = executor.consider(opportunity, episode: {market_pct: 2, support: 1, seconds: 30})
      placed = executor.consider(opportunity, episode: {market_pct: 2, support: 4, seconds: 90})

      expect(refused).to be_nil
      expect(placed[:mode]).to eq("dry_run")
    end
  end

  it "refuses an episode with any doubt, and records why" do
    Dir.mktmpdir do |dir|
      executor = build(dir)

      # LAX 2026-08-04: 99% market disagreement, one observation. The market
      # was right. This exact shape must never become an order.
      intent = executor.consider(opportunity, episode: {market_pct: 99, support: 1, seconds: 19_041})

      expect(intent).to be_nil
      logged = JSON.parse(File.read(File.join(dir, "orders.jsonl")))
      expect(logged["mode"]).to eq("refused")
      expect(logged["doubts"]).to include("market disagrees 99%")
    end
  end

  it "places and records a dry-run intent for a credible opportunity" do
    Dir.mktmpdir do |dir|
      executor = build(dir)

      intent = executor.consider(opportunity, episode: {market_pct: 2, support: 5, seconds: 30})

      expect(intent[:mode]).to eq("dry_run")
      logged = JSON.parse(File.read(File.join(dir, "orders.jsonl")))
      expect(logged["ticker"]).to eq("KXHIGHNY-26AUG04-B83.5")
    end
  end
end
