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
end
