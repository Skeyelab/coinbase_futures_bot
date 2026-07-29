# frozen_string_literal: true

require "rails_helper"

# Issue #479. RapidSignalEvaluationJob is the ONLY path that reaches
# Trading::CoinbasePositions#open_position — RealTimeSignalEvaluator writes
# signal_alerts and places no orders, and Execution::FuturesExecutor ends at a
# log stub. So whatever this job does or fails to do IS live behaviour.
#
# Two verified defects:
#
#   1. Protections were never consulted here. Trading::Protections.blocked? had
#      exactly two callers — the evaluator that does not trade, and the
#      backtester. The whole ADR 0003 epic (#396-#401) wrote locks that the
#      trading path never read, so the simulation was SAFER than production.
#
#   2. open_position returns the raw exchange/dry-run hash, which is STRING
#      keyed ({"success" => true}). This job tested result[:success] — a symbol
#      — so it was always nil: every successful open logged as a failure, no
#      alert was ever sent, and the Position.create! in that branch was dead
#      code. It mattered that the branch was dead: the record is already
#      persisted inside open_position, so "fixing" the key alone would have
#      started double-writing every position.
RSpec.describe RapidSignalEvaluationJob, "live entry path", type: :job do
  let(:contract_id) { "BIT-29AUG25-CDE" }
  let(:strategy) { instance_double(Strategy::MultiTimeframeSignal) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:positions) { instance_double(Trading::CoinbasePositions) }

  let(:signal) do
    {side: "BUY", quantity: 1, confidence: 90, price: 50_000.0, tp: 50_300.0, sl: 49_800.0}
  end

  # What open_position actually returns on the dry-run path.
  let(:success_result) { {"success" => true, "order_id" => "DRY-RUN-1", "dry_run" => true} }

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions)
    allow(contract_manager).to receive(:best_available_contract).and_return(contract_id)
    allow(strategy).to receive(:signal).and_return(signal)
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    Position.destroy_all
    Trading::ProtectionLock.clear!
    # Exposure is #437's concern and has its own specs; these examples are not
    # about it and would otherwise gate on paper-account equity.
    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
  end

  after { Trading::ProtectionLock.clear! }

  def perform!
    described_class.new.perform(product_id: "BTC-USD", current_price: 50_000.0, asset: "BTC")
  end

  describe "protections" do
    it "does not open a position while a protection lock is active" do
      Trading::ProtectionLock.add(source: "stoploss_guard", scope: "global", side: "both",
        reason: "loss cluster", expires_at: 1.hour.from_now)

      expect(positions).not_to receive(:open_position)

      perform!
    end

    it "opens normally when no lock is active" do
      expect(positions).to receive(:open_position).and_return(success_result)

      perform!
    end

    it "honours a symbol-scoped lock for the traded contract" do
      Trading::ProtectionLock.add(source: "cooldown_period", scope: "symbol", symbol: contract_id,
        side: "both", reason: "recent exit", expires_at: 1.hour.from_now)

      expect(positions).not_to receive(:open_position)

      perform!
    end

    it "ignores a lock scoped to a different symbol" do
      Trading::ProtectionLock.add(source: "cooldown_period", scope: "symbol", symbol: "ET-29AUG25-CDE",
        side: "both", reason: "other symbol", expires_at: 1.hour.from_now)

      expect(positions).to receive(:open_position).and_return(success_result)

      perform!
    end
  end

  describe "reading the order result" do
    it "treats a string-keyed success as success" do
      allow(positions).to receive(:open_position).and_return(success_result)
      allow(Rails.logger).to receive(:error)

      perform!

      expect(Rails.logger).not_to have_received(:error).with(/Failed to open position/)
    end

    it "still recognises a failure" do
      allow(positions).to receive(:open_position).and_return({"success" => false, "error" => "rejected"})
      allow(Rails.logger).to receive(:error)

      perform!

      expect(Rails.logger).to have_received(:error).with(/Failed to open position/)
    end

    # open_position already persists the Position internally via
    # create_local_position_record. The job must not write a second one.
    it "does not write a duplicate Position record" do
      allow(positions).to receive(:open_position).and_return(success_result)

      expect { perform! }.not_to change(Position, :count)
    end
  end
end
