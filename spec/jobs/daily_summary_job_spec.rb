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
