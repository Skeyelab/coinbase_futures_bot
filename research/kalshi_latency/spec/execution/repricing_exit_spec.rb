require "json"
require "tmpdir"
require_relative "../../lib/execution/repricing_exit"
require_relative "../../lib/execution/order_client"
require_relative "../../lib/execution/order_log"

RSpec.describe Execution::RepricingExit do
  def build(dir, quotes)
    log = Execution::OrderLog.new(path: File.join(dir, "orders.jsonl"))
    client = Execution::OrderClient.new(transport: ->(*) { raise "dry-run must not reach network" })
    reader = double("reader", quotes: quotes.map { |t, (bid, ask)|
      {ticker: t, bid_cents: bid, ask_cents: ask}
    })
    [described_class.new(client: client, log: log, reader: reader), log]
  end

  def sold_entry(log, ticker: "KXHIGHLAX-26AUG05-B77.5", price: "0.1200")
    # We sold YES on a refuted contract: entry side "ask". Settles at 0;
    # repricing means the ask falls toward it.
    log.record(mode: "dry_run", ticker: ticker, side: "ask", price: price, count: "25.00")
  end

  it "buys back a sold position once the market has repriced to the settled value" do
    Dir.mktmpdir do |dir|
      exit_rule, log = build(dir, "KXHIGHLAX-26AUG05-B77.5" => [1, 3])
      sold_entry(log)

      exits = exit_rule.check

      expect(exits.size).to eq(1)
      lines = File.readlines(File.join(dir, "orders.jsonl")).map { |l| JSON.parse(l) }
      exit_line = lines.last
      expect(exit_line).to include("exit" => true, "side" => "bid", "count" => "25.00")
      expect(exit_line["price"]).to eq("0.0300") # take the 3c offer
      expect(log.open_positions).to be_empty
    end
  end

  it "holds while the remaining edge still pays more than the exit threshold" do
    Dir.mktmpdir do |dir|
      exit_rule, log = build(dir, "KXHIGHLAX-26AUG05-B77.5" => [6, 8])
      sold_entry(log)

      expect(exit_rule.check).to be_empty
      expect(log.open_positions.size).to eq(1)
    end
  end

  it "sells out a bought position once the bid has risen to the settled value" do
    Dir.mktmpdir do |dir|
      log = Execution::OrderLog.new(path: File.join(dir, "orders.jsonl"))
      # We bought YES on a confirmed contract at 94c: entry side "bid".
      log.record(mode: "dry_run", ticker: "KXHIGHMIA-26AUG05-T93", side: "bid",
        price: "0.9400", count: "10.00")
      client = Execution::OrderClient.new(transport: ->(*) { raise "no network" })
      reader = double("reader", quotes: [{ticker: "KXHIGHMIA-26AUG05-T93", bid_cents: 98, ask_cents: 99}])
      exit_rule = described_class.new(client: client, log: log, reader: reader)

      exits = exit_rule.check

      expect(exits.size).to eq(1)
      exit_line = JSON.parse(File.readlines(File.join(dir, "orders.jsonl")).last)
      expect(exit_line).to include("exit" => true, "side" => "ask")
      expect(exit_line["price"]).to eq("0.9800") # hit the 98c bid
    end
  end

  it "does nothing when nothing is open, without touching the reader" do
    Dir.mktmpdir do |dir|
      log = Execution::OrderLog.new(path: File.join(dir, "orders.jsonl"))
      client = Execution::OrderClient.new(transport: ->(*) { raise "no network" })
      reader = double("reader")
      exit_rule = described_class.new(client: client, log: log, reader: reader)

      expect(exit_rule.check).to be_empty
    end
  end

  it "exits a position only once" do
    Dir.mktmpdir do |dir|
      exit_rule, log = build(dir, "KXHIGHLAX-26AUG05-B77.5" => [1, 3])
      sold_entry(log)

      exit_rule.check
      expect(exit_rule.check).to be_empty
    end
  end
end
