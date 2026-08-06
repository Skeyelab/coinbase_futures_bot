require "tmpdir"
require "json"
require_relative "../../lib/execution/loss_stop"
require_relative "../../lib/execution/halt"

RSpec.describe Execution::LossStop do
  def fills_client(rows)
    double("client", portfolio: {"fills" => rows})
  end

  def fill(ticker: "KXHIGHNY-26AUG06-B83.5", side: "no", action: "buy", count: 1,
    price_cents: 99, fee_cents: 1, at: "2026-08-06T14:00:00Z")
    {"ticker" => ticker, "side" => side, "action" => action, "count_fp" => count.to_s,
     "yes_price_dollars" => format("%.4f", price_cents / 100.0),
     "no_price_dollars" => format("%.4f", (100 - price_cents) / 100.0),
     "fee_cost" => format("%.4f", fee_cents / 100.0), "created_time" => at}
  end

  it "is inert when the day's realized loss is inside the budget" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      stop = described_class.new(client: fills_client([]), halt: halt, budget_cents: 1000, data_dir: dir)

      expect(stop.check).to be false
      expect(halt.active?).to be false
    end
  end

  # The account balance is the ground truth for money lost: settlements,
  # fees and fills all land there, and no reconstruction from fills can be
  # wrong about it.
  it "engages the halt once the day's drop exceeds the budget" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      stop = described_class.new(client: fills_client([]), halt: halt, budget_cents: 1000, data_dir: dir)
      stop.mark_open(25_000) # $250.00 at start of day

      expect(stop.check(balance_cents: 24_100)).to be false # -$9.00, inside
      expect(halt.active?).to be false

      expect(stop.check(balance_cents: 23_900)).to be true # -$11.00, breached
      expect(halt.active?).to be true
      expect(halt.reason).to match(/loss stop/i)
    end
  end

  it "does not engage on a profitable day however large the swing" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      stop = described_class.new(client: fills_client([]), halt: halt, budget_cents: 1000, data_dir: dir)
      stop.mark_open(25_000)

      expect(stop.check(balance_cents: 30_000)).to be false
      expect(halt.active?).to be false
    end
  end

  it "remembers the day's opening balance across restarts" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      described_class.new(client: fills_client([]), halt: halt, budget_cents: 1000, data_dir: dir)
        .mark_open(25_000)

      # A fresh instance -- the restart -- must not treat the current balance
      # as a new, lower baseline, or the stop silently resets after every loss.
      restarted = described_class.new(client: fills_client([]), halt: halt,
        budget_cents: 1000, data_dir: dir)
      expect(restarted.check(balance_cents: 23_900)).to be true
    end
  end

  # Mutation L3: dropping the same-day guard in mark_open let every restart
  # re-baseline to the CURRENT balance, so a losing day silently got a fresh
  # $10 budget on each restart -- unbounded daily loss by restart loop.
  it "keeps the original baseline when mark_open is called again mid-day" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      stop = described_class.new(client: fills_client([]), halt: halt,
        budget_cents: 1000, data_dir: dir)
      stop.mark_open(25_000)

      # Restart after a $9 loss: the baseline must stay $250.00, not become
      # $241.00 (which would permit another $10 down to $231).
      expect(stop.mark_open(24_100)).to eq(25_000)
      expect(stop.check(balance_cents: 23_900)).to be true
    end
  end

  # Mutation L5: without the same-day guard in check, YESTERDAY's baseline
  # scores today -- an overnight settlement drop reads as today's loss and
  # halts a day that has not traded.
  it "ignores a stale baseline from a previous day" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      described_class.new(client: fills_client([]), halt: halt, budget_cents: 1000,
        data_dir: dir, clock: -> { Time.utc(2026, 8, 5, 12, 0, 0) }).mark_open(25_000)

      today = described_class.new(client: fills_client([]), halt: halt,
        budget_cents: 1000, data_dir: dir, clock: -> { Time.utc(2026, 8, 6, 12, 0, 0) })

      # No baseline for today yet: nothing to compare, so no halt.
      expect(today.check(balance_cents: 20_000)).to be false
      expect(halt.active?).to be false
    end
  end

  # Mutation L6: a nil baseline coerced to 0 makes `drop = 0 - balance`
  # hugely negative -- the stop reads a $250 account as a massive PROFIT and
  # can never fire. A missing baseline must mean "no comparison", not zero.
  it "does not compare against a missing baseline" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      stop = described_class.new(client: fills_client([]), halt: halt,
        budget_cents: 1000, data_dir: dir)
      # Same day recorded, but no opening balance captured (balance read failed).
      File.write(File.join(dir, described_class::STATE_FILE),
        JSON.generate("day" => Time.now.utc.strftime("%Y-%m-%d")))

      expect(stop.check(balance_cents: 100)).to be false
      expect(halt.active?).to be false
    end
  end

  it "starts a fresh budget on a new UTC day" do
    Dir.mktmpdir do |dir|
      halt = Execution::Halt.new(data_dir: dir)
      clock = -> { Time.utc(2026, 8, 6, 20, 0, 0) }
      stop = described_class.new(client: fills_client([]), halt: halt,
        budget_cents: 1000, data_dir: dir, clock: clock)
      stop.mark_open(25_000)
      expect(stop.check(balance_cents: 23_900)).to be true

      tomorrow = described_class.new(client: fills_client([]), halt: halt,
        budget_cents: 1000, data_dir: dir, clock: -> { Time.utc(2026, 8, 7, 12, 0, 0) })
      tomorrow.mark_open(23_900)

      expect(tomorrow.check(balance_cents: 23_500)).to be false # -$4 on the new day
    end
  end
end
