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

    # BIT-*-CDE is a DATED contract, so it prices at the dated schedule, not the
    # perp 3 bps (issue #459). Contract notional 50_000 * 0.01 = $500:
    #   proportional/side = 500 * 2.0 * 0.0009           = $0.90
    #   floor/side        = 2.0 contracts * $0.85        = $1.70   <- binds
    # Round trip = $3.40. Previously $0.60, because the global perp rate was
    # applied to a contract that has never traded on a perp venue.
    expect(notifier).to receive(:alert).with(
      "info",
      anything,
      a_string_including(
        "Est. cost/round-trip: $3.4 (11.3% of avg win)",
        "Net of costs: $3.2 → PASS"
      )
    )

    ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
      described_class.new.perform(notifier: notifier)
    end
  end

  it "applies the flat per-contract fee floor for small-notional contracts (issue #372)" do
    now = Time.current
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.0001)
    create(:position, paper: true, status: "CLOSED", pnl: 30.0, size: 2.0,
      entry_price: 50_000.0, entry_time: now - 600, close_time: now)

    # Dated floor, not the perp minimum (issue #459). Contract notional
    # 50_000 * 0.0001 = $5, so proportional is negligible and the floor is the
    # whole cost: 2 contracts * $0.85 = $1.70/side -> RT $3.40.
    expect(notifier).to receive(:alert).with(
      "info", anything, a_string_including("Est. cost/round-trip: $3.4")
    )

    ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil,
      TAKER_MIN_FEE_PER_CONTRACT: nil, DATED_FEE_PER_CONTRACT: nil, DATED_TAKER_RATE: nil) do
      described_class.new.perform(notifier: notifier)
    end
  end

  it "prefers recorded actual fees over the estimate (issue #372)" do
    now = Time.current
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)
    create(:position, paper: true, status: "CLOSED", pnl: 30.0, size: 2.0,
      entry_price: 50_000.0, entry_time: now - 600, close_time: now,
      entry_fee: 2.5, exit_fee: 2.5)

    expect(notifier).to receive(:alert).with(
      "info", anything, a_string_including("Est. cost/round-trip: $5.0")
    )

    ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
      described_class.new.perform(notifier: notifier)
    end
  end

  it "fails the cost gate when costs exceed the realized edge" do
    now = Time.current
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)
    # Round-trip cost at the DATED schedule (issue #459): floor 2 * $0.85 per
    # side = $3.40. A thin $0.4 edge is cost-dominated -> FAIL. Under the old
    # perp pricing ($0.60) this same trade looked marginally profitable, which
    # is exactly the misjudgment the per-venue fix removes.
    create(:position, paper: true, status: "CLOSED", pnl: 0.4, size: 2.0,
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
