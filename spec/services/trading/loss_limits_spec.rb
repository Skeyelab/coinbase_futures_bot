# frozen_string_literal: true

require "rails_helper"

# Issue #482. Nothing in the system limited how much could be lost — every
# implemented control governed whether trading was allowed at all.
RSpec.describe Trading::LossLimits, type: :service do
  let(:now) { Time.utc(2026, 7, 27, 12, 0, 0) }

  before do
    BotRuntimeStat.where(key: TradingHalt::STORE_KEY).delete_all
    Position.destroy_all
    allow(DryRun).to receive(:active?).and_return(true)
  end

  def closed!(pnl:, at: now, paper: true)
    create(:position, status: "CLOSED", pnl: pnl, close_time: at, paper: paper)
  end

  it "halts when the daily cap is breached" do
    closed!(pnl: -6.0)
    closed!(pnl: -5.0)

    breach = described_class.evaluate!(now: now)

    expect(breach.window).to eq("daily")
    expect(TradingHalt.risk_halted?).to be true
    expect(TradingHalt.status[:reason]).to match(/daily realized loss/)
  end

  # Net, not gross: a loss followed by a win has not cost the cap.
  it "measures net realized PnL rather than summing losses" do
    closed!(pnl: -12.0)
    closed!(pnl: 9.0)

    expect(described_class.evaluate!(now: now)).to be_nil
    expect(TradingHalt.active?).to be true
  end

  it "halts on the weekly cap even when no single day breaches" do
    6.times { |i| closed!(pnl: -6.0, at: now - (i + 1).days) }

    breach = described_class.evaluate!(now: now)

    expect(breach.window).to eq("weekly")
  end

  # The tuition cap: total across the program, no window.
  it "halts on the cumulative cap regardless of age" do
    closed!(pnl: -60.0, at: now - 200.days)
    closed!(pnl: -45.0, at: now - 100.days)

    breach = described_class.evaluate!(now: now)

    expect(breach.window).to eq("cumulative")
  end

  # Naming the widest breached window is more useful than "today was bad".
  it "reports the widest breach when several trip at once" do
    closed!(pnl: -150.0)

    expect(described_class.evaluate!(now: now).window).to eq("cumulative")
  end

  it "uses a halt that does not expire" do
    closed!(pnl: -150.0)
    described_class.evaluate!(now: now)

    travel_to(now + 30.hours) { expect(TradingHalt.halted?).to be true }
  end

  it "does not overwrite an existing risk halt and lose its original reason" do
    TradingHalt.halt_for_risk!(reason: "manual kill")
    closed!(pnl: -150.0)

    described_class.evaluate!(now: now)

    expect(TradingHalt.status[:reason]).to eq("manual kill")
  end

  # Paper drills must not be polluted by live rows, and vice versa.
  it "counts only positions from the mode currently in force" do
    closed!(pnl: -150.0, paper: false)

    expect(described_class.evaluate!(now: now)).to be_nil
  end

  it "does nothing while profitable" do
    closed!(pnl: 40.0)

    expect(described_class.evaluate!(now: now)).to be_nil
    expect(TradingHalt.active?).to be true
  end

  it "reports realized totals against each cap" do
    closed!(pnl: -4.0)

    status = described_class.status(now: now)

    expect(status[:daily][:realized]).to eq(-4.0)
    expect(status[:daily][:cap]).to eq(10.0)
    expect(status[:breached]).to be_empty
  end
end
