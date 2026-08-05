require "json"
require "tmpdir"
require_relative "../../lib/execution/order_log"

RSpec.describe Execution::OrderLog do
  it "appends each intent as one JSON line with a timestamp" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "orders.jsonl")
      log = described_class.new(path: path, clock: -> { Time.utc(2026, 8, 4, 21, 0, 0) })

      log.record(ticker: "KXHIGHNY-26AUG04-B83.5", mode: "dry_run", yes_price: 12)
      log.record(ticker: "KXHIGHTSATX-26AUG04-B97.5", mode: "dry_run", yes_price: 3)

      lines = File.readlines(path).map { |l| JSON.parse(l) }
      expect(lines.size).to eq(2)
      expect(lines[0]).to include("ticker" => "KXHIGHNY-26AUG04-B83.5", "ts" => "2026-08-04T21:00:00Z")
      expect(lines[1]["ticker"]).to eq("KXHIGHTSATX-26AUG04-B97.5")
    end
  end

  # DATA_DIR is configurable and points somewhere else on exo-mini. Losing the
  # record of an order because its directory did not exist yet is the worst
  # possible moment to fail -- the order is already at the venue.
  it "creates the directory rather than losing the record" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "orders.jsonl")

      described_class.new(path: path).record(ticker: "KXHIGHNY-26AUG05-B82.5")

      expect(File.readlines(path).size).to eq(1)
    end
  end
end
