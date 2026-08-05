require_relative "../../lib/execution/fill_watch"

# A fake order client. Each call to #order pops the next venue state, so a
# test says "resting, then executed" by listing two states.
class FakeOrderClient
  attr_reader :cancelled

  def initialize(states)
    @states = states
    @cancelled = []
  end

  def order(_id)
    (@states.size > 1) ? @states.shift : @states.first
  end

  def cancel(id)
    @cancelled << id
    {action: "cancel", order_id: id, mode: "live"}
  end
end

RSpec.describe Execution::FillWatch do
  # A v2 intent: fixed-point dollar price string, no yes/no leg.
  def intent(count: 5, price: "0.0300")
    {ticker: "KXHIGHAUS-26AUG04-B97.5", order_id: "abc-123", mode: "live",
     count: format("%.2f", count), price: price, side: "bid"}
  end

  def executed(filled: "5.00", cost: "0.150000")
    {"status" => "executed", "fill_count_fp" => filled, "remaining_count_fp" => "0.00",
     "taker_fill_cost_dollars" => cost, "maker_fill_cost_dollars" => "0.000000"}
  end

  it "reports the realized price once the order fills" do
    client = FakeOrderClient.new([executed])
    watch = described_class.new(client: client, sleeper: ->(_) {}, now: -> { 0 })

    result = watch.settle(intent, timeout_seconds: 60)

    # 5 contracts for $0.15 is 3c each -- exactly the limit, so at-or-better.
    expect(result[:status]).to eq("filled")
    expect(result[:filled]).to eq(5)
    expect(result[:realized_price_cents]).to eq(3.0)
    expect(result[:intended_price_cents]).to eq(3)
    expect(result[:at_or_better]).to be(true)
    expect(client.cancelled).to be_empty
  end

  def resting(filled: "0.00", remaining: "5.00", cost: "0.000000")
    {"status" => "resting", "fill_count_fp" => filled, "remaining_count_fp" => remaining,
     "taker_fill_cost_dollars" => cost, "maker_fill_cost_dollars" => "0.000000"}
  end

  # A quote nobody took is not a fill at a good price -- it is no fill. Leaving
  # it resting would let it fill minutes later, unwatched, at a price the model
  # no longer stands behind.
  it "cancels an order still resting when the clock runs out" do
    client = FakeOrderClient.new([resting])
    ticks = [0, 20, 40, 61]
    watch = described_class.new(client: client, sleeper: ->(_) {},
      now: -> { (ticks.size > 1) ? ticks.shift : ticks.first })

    result = watch.settle(intent, timeout_seconds: 60)

    expect(result[:status]).to eq("unfilled")
    expect(result[:filled]).to eq(0)
    expect(result[:realized_price_cents]).to be_nil
    expect(result[:at_or_better]).to be(false)
    expect(client.cancelled).to eq(["abc-123"])
  end

  it "keeps polling while the order is still resting inside the window" do
    client = FakeOrderClient.new([resting, resting, executed])
    ticks = [0, 2, 4, 6]
    watch = described_class.new(client: client, sleeper: ->(_) {},
      now: -> { (ticks.size > 1) ? ticks.shift : ticks.first })

    result = watch.settle(intent, timeout_seconds: 60)

    expect(result[:status]).to eq("filled")
    expect(client.cancelled).to be_empty
  end

  # Two of five taken is not a fill. Scoring it as one inflates gate item #3
  # with orders that mostly did not happen.
  # The venue 404s a just-created order for a beat. The client reports that as
  # nil -- "not yet" -- and the watch must wait it out rather than give up on
  # an order that is already live.
  it "keeps waiting while the venue cannot see the order yet" do
    client = FakeOrderClient.new([nil, nil, executed])
    ticks = [0, 2, 4, 6]
    watch = described_class.new(client: client, sleeper: ->(_) {},
      now: -> { (ticks.size > 1) ? ticks.shift : ticks.first })

    result = watch.settle(intent, timeout_seconds: 60)

    expect(result[:status]).to eq("filled")
    expect(client.cancelled).to be_empty
  end

  # Never visible, window closed. The order still exists at the venue, so it
  # must be cancelled -- and we must not claim it went unfilled when we simply
  # never saw it.
  it "cancels and reports unknown when the order never became visible" do
    client = FakeOrderClient.new([nil])
    ticks = [0, 61]
    watch = described_class.new(client: client, sleeper: ->(_) {},
      now: -> { (ticks.size > 1) ? ticks.shift : ticks.first })

    result = watch.settle(intent, timeout_seconds: 60)

    expect(result[:status]).to eq("unknown")
    expect(result[:at_or_better]).to be(false)
    expect(client.cancelled).to eq(["abc-123"])
  end

  # Selling YES at 26c is economically buying NO at 74c, so the venue reports
  # a fill cost of 0.74. Dividing cost by count and calling it the realized
  # price reports 74c for a sale made at 26c -- and then at_or_better compares
  # 74 >= 26 and passes trivially. Gate item #3 is scored on these two numbers.
  it "reports a sell's realized price in YES terms, not collateral terms" do
    sold = {"status" => "executed", "fill_count_fp" => "1.00", "remaining_count_fp" => "0.00",
            "taker_fill_cost_dollars" => "0.740000", "maker_fill_cost_dollars" => "0.000000"}
    client = FakeOrderClient.new([sold])
    watch = described_class.new(client: client, sleeper: ->(_) {}, now: -> { 0 })

    result = watch.settle(intent(count: 1, price: "0.2600").merge(side: "ask"), timeout_seconds: 60)

    expect(result[:realized_price_cents]).to eq(26.0)
    expect(result[:at_or_better]).to be(true)
  end

  # Same fill, sold one cent WORSE than quoted. Must not read as at-or-better.
  it "faults a sell that filled below the quoted price" do
    sold = {"status" => "executed", "fill_count_fp" => "1.00", "remaining_count_fp" => "0.00",
            "taker_fill_cost_dollars" => "0.750000", "maker_fill_cost_dollars" => "0.000000"}
    client = FakeOrderClient.new([sold])
    watch = described_class.new(client: client, sleeper: ->(_) {}, now: -> { 0 })

    result = watch.settle(intent(count: 1, price: "0.2600").merge(side: "ask"), timeout_seconds: 60)

    expect(result[:realized_price_cents]).to eq(25.0)
    expect(result[:at_or_better]).to be(false)
  end

  it "records a partial fill as partial and cancels the remainder" do
    client = FakeOrderClient.new([resting(filled: "2.00", remaining: "3.00", cost: "0.060000")])
    ticks = [0, 61]
    watch = described_class.new(client: client, sleeper: ->(_) {},
      now: -> { (ticks.size > 1) ? ticks.shift : ticks.first })

    result = watch.settle(intent, timeout_seconds: 60)

    expect(result[:status]).to eq("partial")
    expect(result[:filled]).to eq(2)
    expect(result[:realized_price_cents]).to eq(3.0)
    expect(client.cancelled).to eq(["abc-123"])
  end
end
