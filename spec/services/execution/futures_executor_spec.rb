# frozen_string_literal: true

require "rails_helper"

RSpec.describe Execution::FuturesExecutor, type: :service do
  let(:logger) { instance_double(Logger) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:trade_client) { instance_double(Coinbase::AdvancedTradeClient) }
  let(:executor) { described_class.new(logger: logger) }
  let(:basis_threshold_bps) { 50 }

  before do
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(Coinbase::AdvancedTradeClient).to receive(:new).and_return(trade_client)
    allow(trade_client).to receive(:get_product_ticker).and_return({"best_bid" => "50000.0", "best_ask" => "50100.0"})
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
  end

  describe "#initialize" do
    context "with default parameters" do
      it "initializes with default basis threshold" do
        allow(ENV).to receive(:fetch).with("BASIS_THRESHOLD_BPS", 50).and_return("50")
        executor = described_class.new
        expect(executor.instance_variable_get(:@basis_threshold_bps)).to eq(50)
      end

      it "initializes with Rails logger by default" do
        allow(ENV).to receive(:fetch).with("BASIS_THRESHOLD_BPS", 50).and_return("50")
        allow(Rails).to receive(:logger).and_return(logger)
        executor = described_class.new
        expect(executor.instance_variable_get(:@logger)).to eq(Rails.logger)
      end

      it "creates contract manager" do
        allow(ENV).to receive(:fetch).with("BASIS_THRESHOLD_BPS", 50).and_return("50")
        expect(MarketData::FuturesContractManager).to receive(:new).with(logger: anything)
        described_class.new
      end
    end

    context "with custom parameters" do
      it "uses custom basis threshold" do
        executor = described_class.new(basis_threshold_bps: 100, logger: logger)
        expect(executor.instance_variable_get(:@basis_threshold_bps)).to eq(100)
      end

      it "uses custom logger" do
        custom_logger = instance_double(Logger)
        executor = described_class.new(logger: custom_logger)
        expect(executor.instance_variable_get(:@logger)).to eq(custom_logger)
      end
    end

    context "with environment variable" do
      it "reads basis threshold from environment" do
        allow(ENV).to receive(:fetch).with("BASIS_THRESHOLD_BPS", 50).and_return("75")
        executor = described_class.new
        expect(executor.instance_variable_get(:@basis_threshold_bps)).to eq(75)
      end
    end
  end

  describe "#consider_entry" do
    let(:spot_price) { 50_000.0 }
    let(:futures_product_id) { "BTC-29DEC24-CDE" }
    let(:timestamp) { "2024-01-15T10:00:00Z" }
    let(:trading_contract) { "BTC-29DEC24-CDE" }

    before do
      allow(executor).to receive(:check_and_perform_rollover)
      allow(executor).to receive(:resolve_trading_contract).and_return(trading_contract)
    end

    context "when rollover is not needed" do
      before do
        allow(executor).to receive(:check_and_perform_rollover)
      end

      it "checks for rollover before considering entry" do
        executor.consider_entry(spot_price: spot_price, futures_product_id: futures_product_id)
        expect(executor).to have_received(:check_and_perform_rollover)
      end
    end

    context "when contract resolution succeeds" do
      before do
        allow(executor).to receive(:resolve_trading_contract).and_return(trading_contract)
      end

      context "when basis is within threshold" do
        before do
          allow(trade_client).to receive(:get_product_ticker).and_return(
            {"best_bid" => "50000.0", "best_ask" => "50000.0"}
          )
        end

        it "logs successful entry consideration with mark price and basis" do
          expect(logger).to receive(:info).with(
            /would place order on #{trading_contract}.*basis=0.0bps.*@ #{timestamp}/
          )

          executor.consider_entry(
            spot_price: spot_price,
            futures_product_id: futures_product_id,
            at: timestamp
          )
        end

        it "uses current timestamp when not provided" do
          allow(Time).to receive(:now).and_return(Time.new(2024, 1, 15, 10, 0, 0, "+00:00"))
          expect(logger).to receive(:info).with(/@ 2024-01-15T10:00:00/)

          executor.consider_entry(spot_price: spot_price, futures_product_id: futures_product_id)
        end
      end

      context "when basis exceeds threshold" do
        before do
          allow(executor).to receive(:resolve_trading_contract).and_return(trading_contract)
          allow(trade_client).to receive(:get_product_ticker).and_return(
            {"best_bid" => "52600.0", "best_ask" => "52700.0"} # ~+5% basis on 50k spot
          )
        end

        it "skips entry when basis exceeds threshold" do
          expect(logger).to receive(:info).with(/skip: basis .* > #{basis_threshold_bps}bps/)

          executor.consider_entry(
            spot_price: spot_price,
            futures_product_id: futures_product_id,
            at: timestamp
          )
        end
      end

      context "when mark price fetch fails" do
        before do
          allow(trade_client).to receive(:get_product_ticker).and_raise(StandardError, "API error")
        end

        it "falls back to spot price and proceeds" do
          expect(logger).to receive(:warn).with(/fetch_futures_mark_price failed/)
          expect(logger).to receive(:info).with(/would place order.*basis=0.0bps/)

          executor.consider_entry(
            spot_price: spot_price,
            futures_product_id: futures_product_id,
            at: timestamp
          )
        end
      end
    end

    context "when contract resolution fails" do
      before do
        allow(executor).to receive(:resolve_trading_contract).and_return(nil)
      end

      it "returns early without processing" do
        expect(logger).not_to receive(:info).with(/would place order/)
        expect(logger).not_to receive(:info).with(/skip: basis/)

        executor.consider_entry(spot_price: spot_price, futures_product_id: futures_product_id)
      end
    end
  end

  describe "#check_and_perform_rollover" do
    context "when rollover is needed" do
      before do
        allow(contract_manager).to receive(:rollover_needed?).with(days_before_expiry: 3).and_return(true)
        allow(executor).to receive(:perform_rollover)
      end

      it "logs rollover need" do
        expect(logger).to receive(:info).with("[EXEC] Contract rollover needed")
        executor.check_and_perform_rollover
      end

      it "performs rollover" do
        expect(executor).to receive(:perform_rollover)
        executor.check_and_perform_rollover
      end
    end

    context "when rollover is not needed" do
      before do
        allow(contract_manager).to receive(:rollover_needed?).with(days_before_expiry: 3).and_return(false)
      end

      it "does not perform rollover" do
        expect(executor).not_to receive(:perform_rollover)
        executor.check_and_perform_rollover
      end

      it "does not log rollover message" do
        expect(logger).not_to receive(:info).with(/rollover/)
        executor.check_and_perform_rollover
      end
    end
  end

  describe "#perform_rollover" do
    let(:expiring_contract) { build(:trading_pair, product_id: "BTC-29DEC24-CDE", base_currency: "BTC") }
    let(:expiring_contracts) { [expiring_contract] }
    let(:target_contract) { "BTC-30JAN25-CDE" }

    before do
      allow(contract_manager).to receive(:expiring_contracts).and_return(expiring_contracts)
      allow(contract_manager).to receive(:best_available_contract).and_return(target_contract)
      allow(executor).to receive(:rollover_contract)
    end

    it "gets expiring contracts" do
      expect(contract_manager).to receive(:expiring_contracts).with(days_ahead: 3)
      executor.perform_rollover
    end

    it "finds best available contract for each expiring contract" do
      expect(contract_manager).to receive(:best_available_contract).with("BTC")
      executor.perform_rollover
    end

    it "performs rollover for each contract" do
      expect(executor).to receive(:rollover_contract).with(
        from_contract: "BTC-29DEC24-CDE",
        to_contract: target_contract,
        asset: "BTC"
      )
      executor.perform_rollover
    end

    context "when contract has no underlying asset" do
      let(:contract_without_asset) { build(:trading_pair, product_id: "UNKNOWN-PRODUCT", base_currency: nil) }

      before do
        allow(contract_manager).to receive(:expiring_contracts).and_return([contract_without_asset])
        allow(contract_without_asset).to receive(:underlying_asset).and_return(nil)
      end

      it "skips contracts without underlying asset" do
        expect(executor).not_to receive(:rollover_contract)
        executor.perform_rollover
      end
    end

    context "when no target contract is available" do
      before do
        allow(contract_manager).to receive(:best_available_contract).and_return(nil)
      end

      it "skips rollover when no target contract available" do
        expect(executor).not_to receive(:rollover_contract)
        executor.perform_rollover
      end
    end

    context "when source and target contracts are the same" do
      let(:same_contract) { "BTC-29DEC24-CDE" }

      before do
        allow(contract_manager).to receive(:best_available_contract).and_return(same_contract)
      end

      it "skips rollover when already on target contract" do
        expect(executor).not_to receive(:rollover_contract)
        executor.perform_rollover
      end
    end
  end

  describe "#rollover_contract" do
    let(:from_contract) { "BTC-29DEC24-CDE" }
    let(:to_contract) { "BTC-30JAN25-CDE" }
    let(:asset) { "BTC" }
    let(:positions_service) { instance_double(Trading::CoinbasePositions) }
    let(:open_position) { create(:position, product_id: from_contract, side: "LONG", size: 5, day_trading: true) }

    before do
      allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
      allow(positions_service).to receive(:close_position).and_return({"success" => true})
      allow(positions_service).to receive(:open_position).and_return({"success" => true})
    end

    context "when contracts are different" do
      context "with open positions" do
        before { open_position }

        it "logs rollover start" do
          expect(logger).to receive(:info).with(/Rolling over #{asset} from #{from_contract} to #{to_contract}/)
          executor.rollover_contract(from_contract: from_contract, to_contract: to_contract, asset: asset)
        end

        it "closes position on the expiring contract" do
          expect(positions_service).to receive(:close_position).with(
            product_id: from_contract,
            size: 5.0
          )
          executor.rollover_contract(from_contract: from_contract, to_contract: to_contract, asset: asset)
        end

        it "re-opens equivalent size on the target contract" do
          expect(positions_service).to receive(:open_position).with(
            hash_including(
              product_id: to_contract,
              side: :buy,
              size: 5.0
            )
          )
          executor.rollover_contract(from_contract: from_contract, to_contract: to_contract, asset: asset)
        end

        it "logs rollover completion" do
          expect(logger).to receive(:info).with(/Rollover completed: #{from_contract} -> #{to_contract}/)
          executor.rollover_contract(from_contract: from_contract, to_contract: to_contract, asset: asset)
        end

        context "when close fails" do
          before do
            allow(positions_service).to receive(:close_position).and_raise(StandardError, "close failed")
          end

          it "logs error and skips re-open" do
            expect(logger).to receive(:error).with(/Failed to close #{from_contract}/)
            expect(positions_service).not_to receive(:open_position)
            executor.rollover_contract(from_contract: from_contract, to_contract: to_contract, asset: asset)
          end
        end

        context "when open fails" do
          before do
            allow(positions_service).to receive(:open_position).and_raise(StandardError, "open failed")
          end

          it "logs error but does not raise" do
            expect(logger).to receive(:error).with(/Failed to open #{to_contract}/)
            expect { executor.rollover_contract(from_contract: from_contract, to_contract: to_contract, asset: asset) }.not_to raise_error
          end
        end
      end

      context "with no open positions" do
        it "logs skip and does not call positions service" do
          expect(logger).to receive(:info).with(/No open positions found for #{from_contract}/)
          expect(Trading::CoinbasePositions).not_to receive(:new)
          executor.rollover_contract(from_contract: from_contract, to_contract: to_contract, asset: asset)
        end
      end
    end

    context "when contracts are the same" do
      let(:same_contract) { "BTC-29DEC24-CDE" }

      it "returns early without logging" do
        expect(logger).not_to receive(:info)
        executor.rollover_contract(from_contract: same_contract, to_contract: same_contract, asset: asset)
      end
    end
  end

  describe "#resolve_trading_contract" do
    context "when product_id is nil" do
      it "returns nil" do
        result = executor.resolve_trading_contract(nil)
        expect(result).to be_nil
      end
    end

    context "when product_id is empty" do
      it "returns nil" do
        result = executor.resolve_trading_contract("")
        expect(result).to be_nil
      end
    end

    context "when product_id is nil" do
      it "returns nil" do
        result = executor.resolve_trading_contract(nil)
        expect(result).to be_nil
      end
    end

    context "when product_id is already a specific contract" do
      let(:contract_product_id) { "BTC-29DEC24-CDE" }
      let(:contract) { build(:trading_pair, product_id: contract_product_id) }

      context "when contract exists and is not expired" do
        before do
          allow(TradingPair).to receive(:find_by).and_return(contract)
          allow(contract).to receive(:expired?).and_return(false)
        end

        it "returns the contract product_id" do
          result = executor.resolve_trading_contract(contract_product_id)
          expect(result).to eq(contract_product_id)
        end
      end

      context "when contract is expired" do
        before do
          allow(TradingPair).to receive(:find_by).and_return(contract)
          allow(contract).to receive(:expired?).and_return(true)
        end

        it "logs warning and returns nil" do
          expect(logger).to receive(:warn).with("[EXEC] Contract #{contract_product_id} is expired or not found")
          result = executor.resolve_trading_contract(contract_product_id)
          expect(result).to be_nil
        end
      end

      context "when contract is not found" do
        before do
          allow(TradingPair).to receive(:find_by).and_return(nil)
        end

        it "logs warning and returns nil" do
          expect(logger).to receive(:warn).with("[EXEC] Contract #{contract_product_id} is expired or not found")
          result = executor.resolve_trading_contract(contract_product_id)
          expect(result).to be_nil
        end
      end
    end

    context "when product_id is an asset symbol" do
      let(:asset_symbol) { "BTC" }
      let(:best_contract) { "BTC-29DEC24-CDE" }
      let(:contract) { build(:trading_pair, product_id: best_contract) }

      before do
        allow(contract_manager).to receive(:best_available_contract).and_return(best_contract)
        allow(TradingPair).to receive(:find_by).and_return(contract)
      end

      context "when best contract is current month" do
        before do
          allow(contract).to receive(:current_month?).and_return(true)
          allow(contract).to receive(:upcoming_month?).and_return(false)
        end

        it "logs current month resolution" do
          expect(logger).to receive(:info).with(
            "[EXEC] Resolved #{asset_symbol} to current month contract: #{best_contract}"
          )
          result = executor.resolve_trading_contract(asset_symbol)
          expect(result).to eq(best_contract)
        end
      end

      context "when best contract is upcoming month" do
        before do
          allow(contract).to receive(:current_month?).and_return(false)
          allow(contract).to receive(:upcoming_month?).and_return(true)
        end

        it "logs upcoming month resolution" do
          expect(logger).to receive(:info).with(
            "[EXEC] Resolved #{asset_symbol} to upcoming month contract: #{best_contract} (current month not suitable)"
          )
          result = executor.resolve_trading_contract(asset_symbol)
          expect(result).to eq(best_contract)
        end
      end

      context "when no suitable contract is found" do
        before do
          allow(contract_manager).to receive(:best_available_contract).and_return(nil)
        end

        it "logs warning and returns nil" do
          expect(logger).to receive(:warn).with("[EXEC] No suitable contract found for asset #{asset_symbol}")
          result = executor.resolve_trading_contract(asset_symbol)
          expect(result).to be_nil
        end
      end
    end

    context "when product_id cannot be parsed" do
      let(:unknown_product_id) { "UNKNOWN-PRODUCT" }

      before do
        allow(executor).to receive(:extract_asset_from_product_id).and_return(nil)
      end

      it "returns product_id as-is" do
        result = executor.resolve_trading_contract(unknown_product_id)
        expect(result).to eq(unknown_product_id)
      end
    end
  end

  describe "#extract_asset_from_product_id" do
    context "with simple asset symbols" do
      it "extracts BTC from BTC-USD" do
        result = executor.extract_asset_from_product_id("BTC-USD")
        expect(result).to eq("BTC")
      end

      it "extracts ETH from ETH-USD" do
        result = executor.extract_asset_from_product_id("ETH-USD")
        expect(result).to eq("ETH")
      end

      it "extracts BTC from just BTC" do
        result = executor.extract_asset_from_product_id("BTC")
        expect(result).to eq("BTC")
      end

      it "extracts ETH from just ETH" do
        result = executor.extract_asset_from_product_id("ETH")
        expect(result).to eq("ETH")
      end
    end

    context "with futures contract IDs" do
      it "extracts BTC from BIT futures contract" do
        result = executor.extract_asset_from_product_id("BIT-29DEC24-CDE")
        expect(result).to eq("BTC")
      end

      it "extracts ETH from ET futures contract" do
        result = executor.extract_asset_from_product_id("ET-29DEC24-CDE")
        expect(result).to eq("ETH")
      end
    end

    context "with unknown product formats" do
      it "returns nil for unknown formats" do
        result = executor.extract_asset_from_product_id("UNKNOWN-PRODUCT")
        expect(result).to be_nil
      end

      it "returns nil for empty string" do
        result = executor.extract_asset_from_product_id("")
        expect(result).to be_nil
      end
    end
  end

  describe "integration with SentryServiceTracking" do
    it "includes SentryServiceTracking" do
      expect(described_class.ancestors).to include(SentryServiceTracking)
    end
  end

  describe "error handling" do
    context "when contract manager operations fail" do
      before do
        allow(contract_manager).to receive(:rollover_needed?).and_raise(StandardError.new("Manager error"))
      end

      it "raises errors for contract manager failures" do
        expect do
          executor.check_and_perform_rollover
        end.to raise_error(StandardError, "Manager error")
      end
    end

    context "when trading pair lookup fails" do
      before do
        allow(TradingPair).to receive(:find_by).and_raise(StandardError.new("DB error"))
      end

      it "raises database errors during contract resolution" do
        expect do
          executor.resolve_trading_contract("BTC-29DEC24-CDE")
        end.to raise_error(StandardError, "DB error")
      end
    end
  end

  describe "kill switch guard on #consider_entry" do
    before do
      allow(contract_manager).to receive(:rollover_needed?).and_return(false)
      allow(contract_manager).to receive(:best_available_contract).and_return(nil)
    end

    it "raises TradingHalt::HaltedError when trading is halted" do
      allow(TradingHalt).to receive(:assert_active!).and_raise(TradingHalt::HaltedError, "Trading is halted")
      expect { executor.consider_entry(spot_price: 50_000.0, futures_product_id: "BIT-29AUG25-CDE") }
        .to raise_error(TradingHalt::HaltedError)
    end

    it "proceeds when trading is active" do
      allow(TradingHalt).to receive(:assert_active!)
      allow(contract_manager).to receive(:rollover_needed?).and_return(false)
      allow(executor).to receive(:resolve_trading_contract).and_return(nil)
      expect { executor.consider_entry(spot_price: 50_000.0, futures_product_id: "BIT-29AUG25-CDE") }
        .not_to raise_error
    end
  end
end
