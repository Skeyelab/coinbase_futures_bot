# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::CurrentEquity do
  describe ".usd" do
    it "returns actual paper equity in dry-run (so the guard sees a real curve)" do
      DryRun.enable!
      allow(PaperAccount).to receive(:new).and_return(instance_double(PaperAccount, equity: 8_250.0))

      expect(described_class.usd).to eq(8_250.0)
    end

    it "returns the live CFM account balance when live" do
      DryRun.disable!
      client = instance_double(Coinbase::Client, futures_balance_summary: {"total_usd_balance" => "12500.75"})

      expect(described_class.usd(client: client)).to eq(12_500.75)
    end

    it "falls back to the sizing figure when the live balance can't be read (degrades safely)" do
      DryRun.disable!
      client = instance_double(Coinbase::Client)
      allow(client).to receive(:futures_balance_summary).and_raise(StandardError, "no auth")

      ClimateControl.modify(SIGNAL_EQUITY_USD: "10000") do
        expect(described_class.usd(client: client)).to eq(10_000.0)
      end
    end
  end

  # The point of #451: feeding actual equity revives the MaxDrawdown circuit
  # breaker (#401), which could never fire against a static constant.
  describe "reviving the MaxDrawdown guard" do
    before do
      DryRun.enable!
      Trading::ProtectionLock.clear!
      # Seed the peak the way production does — through the monitor — so the
      # sample carries the regime and timestamp the #608 fix requires.
      Trading::Protections::MaxDrawdownMonitor.evaluate(current_equity: 10_000.0)
    end

    it "breaches when actual paper equity falls past the drawdown ceiling" do
      allow(PaperAccount).to receive(:new).and_return(instance_double(PaperAccount, equity: 8_000.0)) # -20%

      Trading::Protections::MaxDrawdownMonitor.evaluate(current_equity: described_class.usd)

      expect(Trading::ProtectionLock.active).not_to be_empty
    end

    it "does not breach within the ceiling" do
      allow(PaperAccount).to receive(:new).and_return(instance_double(PaperAccount, equity: 9_800.0)) # -2%

      Trading::Protections::MaxDrawdownMonitor.evaluate(current_equity: described_class.usd)

      expect(Trading::ProtectionLock.active).to be_empty
    end
  end
end
