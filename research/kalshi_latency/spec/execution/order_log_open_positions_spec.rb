require "json"
require "tmpdir"
require_relative "../../lib/execution/order_log"

RSpec.describe Execution::OrderLog, "#open_positions" do
  def log_in(dir)
    described_class.new(path: File.join(dir, "orders.jsonl"))
  end

  it "returns placed intents that have not been exited" do
    Dir.mktmpdir do |dir|
      log = log_in(dir)
      log.record(mode: "dry_run", ticker: "KXHIGHNY-26AUG05-B84.5", side: "ask",
        price: "0.1200", count: "25.00")

      open = log.open_positions
      expect(open.size).to eq(1)
      expect(open.first).to include("ticker" => "KXHIGHNY-26AUG05-B84.5", "side" => "ask")
    end
  end

  it "drops a position once an exit is recorded for its ticker" do
    Dir.mktmpdir do |dir|
      log = log_in(dir)
      log.record(mode: "dry_run", ticker: "KXHIGHNY-26AUG05-B84.5", side: "ask",
        price: "0.1200", count: "25.00")
      log.record(mode: "dry_run", ticker: "KXHIGHNY-26AUG05-B84.5", side: "bid",
        price: "0.0300", count: "25.00", exit: true)

      expect(log.open_positions).to be_empty
    end
  end

  it "ignores refusals and halts" do
    Dir.mktmpdir do |dir|
      log = log_in(dir)
      log.record(mode: "refused", ticker: "A", doubts: ["market disagrees 99%"])
      log.record(mode: "halted", ticker: "B", reason: "ops")

      expect(log.open_positions).to be_empty
    end
  end
end
