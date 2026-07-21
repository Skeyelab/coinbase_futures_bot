# frozen_string_literal: true

require "rails_helper"

RSpec.describe DailySummaryJob, type: :job do
  let(:notifier) { class_double(SlackNotificationService) }

  it "posts a paper-trade summary (trades, win rate, PnL, MAE, holding) to Slack" do
    now = Time.current
    create(:position, paper: true, status: "CLOSED", pnl: 30.0,
      entry_time: now - 600, close_time: now, max_adverse_excursion: -12.0)
    create(:position, paper: true, status: "CLOSED", pnl: -20.0,
      entry_time: now - 300, close_time: now, max_adverse_excursion: -25.0)

    expect(notifier).to receive(:alert).with(
      "info",
      a_string_including("Daily Paper Summary"),
      a_string_including("Trades: 2", "50.0% win rate", "Realized PnL: $10.0", "Worst MAE: $-25.0")
    )

    described_class.new.perform(notifier: notifier)
  end

  it "surfaces estimated taker costs and the net-of-costs verdict (issue #353)" do
    now = Time.current
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)
    create(:position, paper: true, status: "CLOSED", pnl: 30.0, size: 2.0,
      entry_price: 50_000.0, entry_time: now - 600, close_time: now)
    create(:position, paper: true, status: "CLOSED", pnl: -20.0, size: 2.0,
      entry_price: 50_000.0, entry_time: now - 300, close_time: now)

    # per-trade round trip at taker 15 bps on both sides of the contract-size
    # notional (exit approximated by entry): 2 * 50_000 * 0.01 * 2.0 * 0.0015 = 3.0
    expect(notifier).to receive(:alert).with(
      "info",
      anything,
      a_string_including(
        "Est. cost/round-trip: $3.0 (10.0% of avg win)",
        "Net of costs: $4.0 → PASS"
      )
    )

    ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
      described_class.new.perform(notifier: notifier)
    end
  end

  it "fails the cost gate when costs exceed the realized edge" do
    now = Time.current
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)
    create(:position, paper: true, status: "CLOSED", pnl: 2.0, size: 2.0,
      entry_price: 50_000.0, entry_time: now - 600, close_time: now)

    expect(notifier).to receive(:alert).with(
      "info", anything, a_string_including("→ FAIL")
    )

    ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
      described_class.new.perform(notifier: notifier)
    end
  end

  it "handles a day with no trades without erroring" do
    expect(notifier).to receive(:alert).with("info", anything, a_string_including("Trades: 0"))

    described_class.new.perform(notifier: notifier)
  end

  it "excludes trades older than the window and non-paper trades" do
    now = Time.current
    create(:position, paper: true, status: "CLOSED", pnl: 5.0, entry_time: now - 200, close_time: now - 2.days) # too old
    create(:position, paper: false, status: "CLOSED", pnl: 999.0, entry_time: now - 200, close_time: now) # not paper

    expect(notifier).to receive(:alert).with("info", anything, a_string_including("Trades: 0"))

    described_class.new.perform(notifier: notifier)
  end
end
