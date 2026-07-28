# frozen_string_literal: true

require "rails_helper"

# One source for paper PnL over a window. Extracted because a second, wrong copy
# in the day-trading Slack card reported $0 on a profitable day.
RSpec.describe Trading::PaperPnlSummary do
  def closed_paper(pnl:, closed_at: 1.hour.ago, entry: 100.0)
    Position.create!(
      product_id: "NOL-19AUG26-CDE", side: "SHORT", size: 1, entry_price: entry,
      entry_time: closed_at - 1.hour, close_time: closed_at, status: "CLOSED",
      pnl: pnl, paper: true, day_trading: true
    )
  end

  def open_paper(pnl:, entry: 100.0)
    Position.create!(
      product_id: "NOL-19AUG26-CDE", side: "SHORT", size: 1, entry_price: entry,
      entry_time: 1.hour.ago, status: "OPEN", pnl: pnl, paper: true, day_trading: true
    )
  end

  subject(:summary) { described_class.call(since: 24.hours.ago) }

  it "reports realized PnL and win rate from closed trades" do
    closed_paper(pnl: 32.0)
    closed_paper(pnl: 32.75)
    closed_paper(pnl: -6.4)

    expect(summary[:trades]).to eq(3)
    expect(summary[:wins]).to eq(2)
    expect(summary[:win_rate]).to eq(66.7)
    expect(summary[:realized_pnl]).to eq(58.35)
  end

  # The exact failure that produced "Total PnL $0" on a +$62.65 day.
  it "keeps unrealized separate from realized, so a profitable day with nothing open is not zero" do
    closed_paper(pnl: 32.0)
    closed_paper(pnl: 30.65)

    expect(summary[:open]).to eq(0)
    expect(summary[:unrealized_pnl]).to eq(0.0)
    expect(summary[:realized_pnl]).to eq(62.65)
  end

  it "counts unrealized PnL from open positions" do
    open_paper(pnl: 12.5)

    expect(summary[:open]).to eq(1)
    expect(summary[:unrealized_pnl]).to eq(12.5)
  end

  it "excludes trades closed before the window" do
    closed_paper(pnl: 99.0, closed_at: 3.days.ago)

    expect(summary[:trades]).to eq(0)
    expect(summary[:realized_pnl]).to eq(0.0)
  end

  it "reports an empty window without dividing by zero" do
    expect(summary[:trades]).to eq(0)
    expect(summary[:win_rate]).to eq(0.0)
    expect(summary[:net_of_costs]).to be_nil
  end
end
