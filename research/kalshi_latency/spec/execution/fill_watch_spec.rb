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
  def intent(count: 5, price: 3)
    {ticker: "KXHIGHAUS-26AUG04-B97.5", order_id: "abc-123", mode: "live",
     count: count, no_price: price, side: "no", action: "sell"}
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
