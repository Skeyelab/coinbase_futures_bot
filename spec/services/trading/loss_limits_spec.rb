# frozen_string_literal: true

require "rails_helper"

# Issue #482. Nothing in the system limited how much could be lost — every
# implemented control governed whether trading was allowed at all.
RSpec.describe Trading::LossLimits, type: :service do
  let(:now) { Time.utc(2026, 7, 27, 12, 0, 0) }

  # These examples assert the LIVE caps ($10/$30/$100, #392 condition 3), so
  # they run in the mode those caps govern: dry-run OFF, live rows.
  before do
    BotRuntimeStat.where(key: TradingHalt::STORE_KEY).delete_all
    Position.destroy_all
    allow(DryRun).to receive(:active?).and_return(false)
  end

  def closed!(pnl:, at: now, paper: false)
    create(:position, status: "CLOSED", pnl: pnl, close_time: at, paper: paper)
  end

  def with_env(pairs)
    previous = pairs.keys.to_h { |key| [key, ENV[key]] }
    pairs.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
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
    closed!(pnl: -150.0, paper: true)

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

  # Issue #392's caps size real capital. Paper protects nothing, and the halt it
  # writes never auto-expires (#481), so a $10 daily cap turned one ordinary
  # NOL-19AUG26-CDE stop-out (-$12.60 on 2026-07-28) into a manual clear and
  # stopped the >=100-trades-per-symbol sample #376 gate 2 needs.
  describe "paper caps" do
    let(:paper_equity) { 1_000.0 }

    before do
      allow(DryRun).to receive(:active?).and_return(true)
      allow(PaperAccount).to receive(:starting_equity).and_return(paper_equity)
    end

    it "does not halt paper on a loss that would breach the live daily cap" do
      closed!(pnl: -12.60, paper: true)

      expect(described_class.evaluate!(now: now)).to be_nil
      expect(TradingHalt.risk_halted?).to be false
    end

    # Defaults track PAPER_EQUITY_USD so raising paper equity raises the caps
    # with it, instead of leaving a one-contract account behind.
    it "default to a fraction of paper equity, keeping #392's 1:3:10 shape" do
      expect(described_class.paper_daily_cap).to eq(100.0)
      expect(described_class.paper_weekly_cap).to eq(300.0)
      expect(described_class.paper_cumulative_cap).to eq(1_000.0)
    end

    it "scale when the operator raises PAPER_EQUITY_USD" do
      allow(PaperAccount).to receive(:starting_equity).and_return(10_000.0)

      expect(described_class.paper_daily_cap).to eq(1_000.0)
    end

    it "yield to an explicit PAPER_LOSS_CAP_DAILY_USD override" do
      with_env("PAPER_LOSS_CAP_DAILY_USD" => "5") do
        closed!(pnl: -6.0, paper: true)

        expect(described_class.evaluate!(now: now).window).to eq("daily")
      end
    end

    # Paper is not a licence to be unstoppable: a real breach still writes the
    # same non-expiring risk halt, and an operator still has to clear it.
    it "still write a real, non-expiring risk halt when actually breached" do
      closed!(pnl: -1_200.0, paper: true)

      breach = described_class.evaluate!(now: now)

      expect(breach.window).to eq("cumulative")
      expect(TradingHalt.risk_halted?).to be true
      travel_to(now + 30.hours) { expect(TradingHalt.halted?).to be true }
    end
  end

  # #392 is a governance contract. Whatever paper does, these three numbers and
  # the env vars that carry them keep their meaning.
  describe "live defaults" do
    it "are still $10 daily, $30 weekly, $100 cumulative" do
      expect(described_class.live_daily_cap).to eq(10.0)
      expect(described_class.live_weekly_cap).to eq(30.0)
      expect(described_class.live_cumulative_cap).to eq(100.0)
    end

    it "yield to an explicit LOSS_CAP_DAILY_USD override" do
      with_env("LOSS_CAP_DAILY_USD" => "50") do
        closed!(pnl: -12.60)

        expect(described_class.evaluate!(now: now)).to be_nil
      end
    end

    it "are not raised by the paper env vars" do
      with_env("PAPER_LOSS_CAP_DAILY_USD" => "500") do
        closed!(pnl: -12.60)

        expect(described_class.evaluate!(now: now).window).to eq("daily")
      end
    end
  end

  # The cap and the sample must never be scoped to different modes. DryRun is a
  # DB-backed toggle another process can flip between two calls, so LossLimits
  # reads it once and derives both from that answer. A second read would let a
  # live cap ($30 weekly) be applied to paper rows, or the reverse — worse than
  # the shared cap this replaced. One example per read ordering.
  describe "the cap and the sample share one notion of mode" do
    before { allow(PaperAccount).to receive(:starting_equity).and_return(1_000.0) }

    # -$50 is inside the $100 paper daily cap and past the $30 live weekly cap.
    it "cannot apply a live cap to paper rows when the toggle flips mid-evaluation" do
      closed!(pnl: -50.0, paper: true)
      allow(DryRun).to receive(:active?).and_return(true, false)

      expect(described_class.evaluate!(now: now)).to be_nil
      expect(TradingHalt.risk_halted?).to be false
    end

    it "cannot pull paper rows into a live evaluation when the toggle flips mid-evaluation" do
      closed!(pnl: -50.0, paper: true)
      allow(DryRun).to receive(:active?).and_return(false, true)

      expect(described_class.evaluate!(now: now)).to be_nil
      expect(TradingHalt.risk_halted?).to be false
    end
  end
end
