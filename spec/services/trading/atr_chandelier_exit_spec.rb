# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::AtrChandelierExit do
  # Defaults mirror the live n8n CFG: trailAtr 2.5, fixedStop -75.
  subject(:policy) { described_class.new(trail_atr: 2.5, fixed_stop: -75.0) }

  # NOL nano oil: contract_size 10, so one ATR point on 2 contracts is $20 of PnL.
  # UNSET rather than nil: `peak || net_pnl` would silently turn an explicit nil
  # into net_pnl, so the "cannot evaluate" case would never actually be tested.
  let(:unset) { Object.new }

  def evaluate(net_pnl:, peak: unset, atr: 1.0, contracts: 2.0, stored_stop: nil)
    policy.evaluate(
      net_pnl: net_pnl,
      peak_net_pnl: peak.equal?(unset) ? net_pnl : peak,
      atr: atr,
      contract_size: 10.0,
      contracts: contracts,
      stored_stop: stored_stop
    )
  end

  describe "#evaluate" do
    it "holds a position sitting well above its trailing stop" do
      # peak 0, atr_pnl = 1 * 10 * 2 = 20, so stop = max(-75, 0 - 50) = -50.
      result = evaluate(net_pnl: 0.0, peak: 0.0)

      expect(result[:stop]).to be_within(1e-9).of(-50.0)
      expect(result[:reason]).to be_nil
    end

    it "exits once net PnL reaches the trailing stop" do
      # peak 100, atr_pnl 20, stop = 100 - 50 = 50. Sitting exactly on it exits.
      result = evaluate(net_pnl: 50.0, peak: 100.0)

      expect(result[:stop]).to be_within(1e-9).of(50.0)
      expect(result[:reason]).to eq(:atr_trail)
    end

    it "floors the stop at the absolute dollar stop" do
      # peak 0, atr_pnl 200 would put the trail at -500; the floor wins.
      result = evaluate(net_pnl: -10.0, peak: 0.0, atr: 10.0)

      expect(result[:stop]).to be_within(1e-9).of(-75.0)
      expect(result[:reason]).to be_nil
      expect(result[:basis]).to eq(:atr)
    end

    it "reports hitting the floor distinctly from hitting the trail" do
      result = evaluate(net_pnl: -80.0, peak: 0.0, atr: 10.0)

      expect(result[:reason]).to eq(:atr_floor)
    end

    # Losing ATR must degrade to WIDER and dumber, never tighter. A percentage
    # ladder or a tightened stop on missing data would exit positions precisely
    # when the system knows least.
    it "falls back to the absolute stop when ATR is unusable" do
      [nil, 0.0, -1.0].each do |bad_atr|
        result = evaluate(net_pnl: 0.0, peak: 100.0, atr: bad_atr)

        expect(result[:stop]).to be_within(1e-9).of(-75.0)
        expect(result[:basis]).to eq(:fixed_fallback)
      end
    end

    it "ratchets the stop upward and never back down" do
      # ATR widens, so the freshly computed trail (100 - 100 = 0) is LOWER than
      # the stored stop of 50. The stored one must win.
      result = evaluate(net_pnl: 60.0, peak: 100.0, atr: 5.0, stored_stop: 50.0)

      expect(result[:stop]).to be_within(1e-9).of(50.0)
      expect(result[:reason]).to be_nil
    end

    it "raises the stop when the fresh trail is higher than the stored one" do
      result = evaluate(net_pnl: 90.0, peak: 120.0, atr: 1.0, stored_stop: 50.0)

      expect(result[:stop]).to be_within(1e-9).of(70.0)
    end

    # A stored stop from a different regime cannot be trusted. Resetting can
    # LOOSEN the stop, which is intended -- it is the only way a changed
    # parameter reaches an already-open position.
    it "ignores a stored stop while the position has never been in profit" do
      result = evaluate(net_pnl: -60.0, peak: -10.0, atr: 1.0, stored_stop: 50.0)

      expect(result[:stop]).to be_within(1e-9).of(-60.0)
    end

    it "scales the trail with contract count" do
      one = evaluate(net_pnl: 0.0, peak: 100.0, contracts: 1.0)
      four = evaluate(net_pnl: 0.0, peak: 100.0, contracts: 4.0)

      expect(one[:stop]).to be_within(1e-9).of(75.0)   # 100 - 2.5*1*10*1
      expect(four[:stop]).to be_within(1e-9).of(0.0)   # 100 - 2.5*1*10*4
    end

    it "holds rather than exits on inputs it cannot evaluate" do
      expect(evaluate(net_pnl: nil, peak: 100.0)[:reason]).to be_nil
      expect(evaluate(net_pnl: -100.0, peak: nil)[:reason]).to be_nil
      expect(evaluate(net_pnl: -100.0, peak: 0.0, contracts: 0.0)[:reason]).to be_nil
    end
  end

  describe "#enabled?" do
    it "is inert without both thresholds" do
      expect(described_class.new(trail_atr: nil, fixed_stop: -75.0)).not_to be_enabled
      expect(described_class.new(trail_atr: 2.5, fixed_stop: nil)).not_to be_enabled
      expect(described_class.new(trail_atr: 0, fixed_stop: -75.0)).not_to be_enabled
      expect(described_class.new(trail_atr: 2.5, fixed_stop: -75.0)).to be_enabled
    end
  end
end
