# frozen_string_literal: true

require "rails_helper"

# The operator's real exit rule, ported from the n8n workflow that has been running
# outside this bot (docs/plans/2026-07-29-trailing-profit-giveback-exit-design.md):
# arm once net profit per contract clears a threshold, then exit on giving back a
# fraction of the peak. Pure decision function — the caller owns peak tracking and
# nets the round-trip fee, so live (a Position column) and backtest (a per-order
# hash) share one rule.
RSpec.describe Trading::TrailingGivebackExit, type: :service do
  subject(:policy) do
    described_class.new(arm_at: 25.0, giveback: 0.30, hard_stop: 15.0)
  end

  describe "#exit_reason" do
    it "exits (:trailing_giveback) once an armed position gives back its share of peak" do
      # peak $30 >= $25 arm -> armed. floor = 30 * (1 - 0.30) = $21.
      expect(policy.exit_reason(net_pnl: 22.0, peak_net_pnl: 30.0, contracts: 1)).to be_nil
      expect(policy.exit_reason(net_pnl: 21.0, peak_net_pnl: 30.0, contracts: 1)).to eq(:trailing_giveback)
    end

    it "stops out (:trailing_hard_stop) on an unarmed position at the hard stop" do
      # peak $10 never reached the $25 arm, so the giveback floor never applies and
      # the flat hard stop is the only exit.
      expect(policy.exit_reason(net_pnl: -14.0, peak_net_pnl: 10.0, contracts: 1)).to be_nil
      expect(policy.exit_reason(net_pnl: -15.0, peak_net_pnl: 10.0, contracts: 1)).to eq(:trailing_hard_stop)
    end

    # The whole point of per-contract thresholds: a flat per-contract fee makes a
    # fixed TOTAL target decay to nothing as size grows (a $10 total target nets
    # negative by six oil contracts). Both thresholds scale with size; the giveback
    # floor does not, because peak_net_pnl is already a total.
    it "scales the arm threshold and hard stop with contract count" do
      # $60 peak arms one contract ($25) but not three ($75).
      expect(policy.exit_reason(net_pnl: 30.0, peak_net_pnl: 60.0, contracts: 3)).to be_nil

      # $90 peak clears the $75 arm; floor = 90 * 0.7 = $63.
      expect(policy.exit_reason(net_pnl: 64.0, peak_net_pnl: 90.0, contracts: 3)).to be_nil
      expect(policy.exit_reason(net_pnl: 63.0, peak_net_pnl: 90.0, contracts: 3)).to eq(:trailing_giveback)

      # Unarmed hard stop is $15 x 3 = $45.
      expect(policy.exit_reason(net_pnl: -44.0, peak_net_pnl: 10.0, contracts: 3)).to be_nil
      expect(policy.exit_reason(net_pnl: -45.0, peak_net_pnl: 10.0, contracts: 3)).to eq(:trailing_hard_stop)
    end

    # Every uncertain input holds rather than closing: a missing price or an
    # unresolvable size must never manufacture an exit.
    it "holds on missing or zero inputs" do
      expect(policy.exit_reason(net_pnl: nil, peak_net_pnl: 30.0, contracts: 1)).to be_nil
      expect(policy.exit_reason(net_pnl: -99.0, peak_net_pnl: nil, contracts: 1)).to be_nil
      expect(policy.exit_reason(net_pnl: -99.0, peak_net_pnl: 30.0, contracts: 0)).to be_nil
      expect(policy.exit_reason(net_pnl: -99.0, peak_net_pnl: 30.0, contracts: nil)).to be_nil
    end
  end

  describe "#enabled?" do
    # A giveback of 0 makes the floor equal the peak, so the position exits on the
    # tick it peaks. A giveback of 1 puts the floor at $0 and hands back every
    # dollar. Both are misconfigurations, and validating beats clamping: silently
    # "fixing" a bad number hides it.
    # exit_reason computes -(hard_stop * contracts) on the unarmed branch, so a
    # config with arm + giveback but no hard stop would raise on every tick inside
    # check_position_alerts. enabled? is the gate that has to catch it.
    it "is disabled when no hard stop is configured" do
      expect(described_class.new(arm_at: 25.0, giveback: 0.30, hard_stop: nil)).not_to be_enabled
    end

    it "is disabled for a giveback fraction outside (0,1)" do
      expect(described_class.new(arm_at: 25.0, giveback: 0.0, hard_stop: 15.0)).not_to be_enabled
      expect(described_class.new(arm_at: 25.0, giveback: 1.0, hard_stop: 15.0)).not_to be_enabled
      expect(described_class.new(arm_at: 25.0, giveback: -0.1, hard_stop: 15.0)).not_to be_enabled
      expect(described_class.new(arm_at: 25.0, giveback: 0.30, hard_stop: 15.0)).to be_enabled
    end
  end

  describe ".from_config" do
    def with_config(cfg)
      base = Rails.application.config.real_time_signals
      allow(Rails.application.config).to receive(:real_time_signals)
        .and_return(base.merge(trailing_giveback: cfg))
      yield
    end

    it "is inert when no arm threshold is configured" do
      with_config({}) do
        expect(described_class.from_config).not_to be_enabled
      end
    end

    # Asserted through behavior rather than attribute readers: what matters is that
    # a config of 25/0.30/15 decides like a policy of 25/0.30/15.
    it "decides according to the configured thresholds" do
      cfg = {
        arm_at_per_contract_usd: 25.0,
        giveback_fraction: 0.30,
        hard_stop_per_contract_usd: 15.0
      }
      with_config(cfg) do
        configured = described_class.from_config
        expect(configured).to be_enabled
        expect(configured.exit_reason(net_pnl: 22.0, peak_net_pnl: 30.0, contracts: 1)).to be_nil
        expect(configured.exit_reason(net_pnl: 21.0, peak_net_pnl: 30.0, contracts: 1)).to eq(:trailing_giveback)
        expect(configured.exit_reason(net_pnl: -15.0, peak_net_pnl: 10.0, contracts: 1)).to eq(:trailing_hard_stop)
      end
    end
  end
end
