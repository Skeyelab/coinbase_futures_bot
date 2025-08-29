# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::FuturesContractManager, type: :service do
  let(:manager) { described_class.new }
  let(:current_date) { Date.new(2025, 8, 15) } # Mid-August 2025

  before do
    # Mock Date.current to return a fixed date for testing
    allow(Date).to receive(:current).and_return(current_date)
  end

  describe "#generate_current_month_contract_id" do
    it "generates BTC contract ID for current month" do
      # Mock finding the last Friday of August 2025 (which would be August 29th, 2025)
      contract_id = manager.generate_current_month_contract_id("BTC")
      expect(contract_id).to eq("BIT-29AUG25-CDE")
    end

    it "generates ETH contract ID for current month" do
      contract_id = manager.generate_current_month_contract_id("ETH")
      expect(contract_id).to eq("ET-29AUG25-CDE")
    end

    it "returns nil for unsupported assets" do
      contract_id = manager.generate_current_month_contract_id("DOGE")
      expect(contract_id).to be_nil
    end
  end

  describe "#discover_current_month_contract" do
    it "creates BTC current month contract if it does not exist" do
      expect(TradingPair.find_by(product_id: "BIT-29AUG25-CDE")).to be_nil

      contract_id = manager.discover_current_month_contract("BTC")
      expect(contract_id).to eq("BIT-29AUG25-CDE")

      trading_pair = TradingPair.find_by(product_id: "BIT-29AUG25-CDE")
      expect(trading_pair).to be_present
      expect(trading_pair.base_currency).to eq("BTC")
      expect(trading_pair.quote_currency).to eq("USD")
      expect(trading_pair.expiration_date).to eq(Date.new(2025, 8, 29))
      expect(trading_pair.contract_type).to eq("CDE")
      expect(trading_pair.enabled).to be true
    end

    it "returns existing contract ID if contract already exists" do
      # Create existing contract
      TradingPair.create!(
        product_id: "BIT-29AUG25-CDE",
        base_currency: "BTC",
        quote_currency: "USD",
        expiration_date: Date.new(2025, 8, 29),
        contract_type: "CDE",
        enabled: true
      )

      contract_id = manager.discover_current_month_contract("BTC")
      expect(contract_id).to eq("BIT-29AUG25-CDE")
    end
  end

  describe "#current_month_contract" do
    context "when current month contract exists" do
      let!(:btc_contract) do
        TradingPair.create!(
          product_id: "BIT-29AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 8, 29),
          contract_type: "CDE",
          enabled: true
        )
      end

      it "returns the existing contract ID" do
        expect(manager.current_month_contract("BTC")).to eq("BIT-29AUG25-CDE")
      end
    end

    context "when no current month contract exists" do
      it "discovers and creates the contract" do
        expect(manager.current_month_contract("BTC")).to eq("BIT-29AUG25-CDE")
        expect(TradingPair.find_by(product_id: "BIT-29AUG25-CDE")).to be_present
      end
    end
  end

  describe "#active_futures_contracts" do
    let!(:btc_current) { TradingPair.create!(product_id: "BIT-29AUG25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 8, 29), enabled: true) }
    let!(:eth_current) { TradingPair.create!(product_id: "ET-29AUG25-CDE", base_currency: "ETH", quote_currency: "USD", expiration_date: Date.new(2025, 8, 29), enabled: true) }
    let!(:btc_next) { TradingPair.create!(product_id: "BIT-30SEP25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 9, 30), enabled: true) }
    let!(:expired_contract) { TradingPair.create!(product_id: "BIT-31JUL25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 7, 31), enabled: true) }
    let!(:disabled_contract) { TradingPair.create!(product_id: "BIT-31DEC25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 12, 31), enabled: false) }

    it "returns only active, non-expired futures contracts" do
      active_contracts = manager.active_futures_contracts
      expect(active_contracts).to contain_exactly(btc_current, eth_current, btc_next)
      expect(active_contracts).not_to include(expired_contract, disabled_contract)
    end
  end

  describe "#expiring_contracts" do
    let!(:expiring_soon) { TradingPair.create!(product_id: "BIT-17AUG25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 8, 17), enabled: true) }
    let!(:expiring_later) { TradingPair.create!(product_id: "BIT-29AUG25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 8, 29), enabled: true) }
    let!(:expiring_next_month) { TradingPair.create!(product_id: "BIT-30SEP25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 9, 30), enabled: true) }

    it "returns contracts expiring within specified days" do
      # Test with 7 days ahead (default)
      expiring = manager.expiring_contracts
      expect(expiring).to contain_exactly(expiring_soon)
    end

    it "returns contracts expiring within custom days ahead" do
      # Test with 20 days ahead
      expiring = manager.expiring_contracts(days_ahead: 20)
      expect(expiring).to contain_exactly(expiring_soon, expiring_later)
    end
  end

  describe "#rollover_needed?" do
    context "when contracts are expiring soon" do
      let!(:expiring_soon) { TradingPair.create!(product_id: "BIT-17AUG25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 8, 17), enabled: true) }

      it "returns true" do
        expect(manager.rollover_needed?).to be true
      end
    end

    context "when no contracts are expiring soon" do
      let!(:expiring_later) { TradingPair.create!(product_id: "BIT-30SEP25-CDE", base_currency: "BTC", quote_currency: "USD", expiration_date: Date.new(2025, 9, 30), enabled: true) }

      it "returns false" do
        expect(manager.rollover_needed?).to be false
      end
    end
  end

  describe "#generate_upcoming_month_contract_id" do
    it "generates BTC contract ID for upcoming month" do
      # Mock finding the last Friday of September 2025 (which would be September 26th, 2025)
      contract_id = manager.generate_upcoming_month_contract_id("BTC")
      expect(contract_id).to eq("BIT-26SEP25-CDE")
    end

    it "generates ETH contract ID for upcoming month" do
      contract_id = manager.generate_upcoming_month_contract_id("ETH")
      expect(contract_id).to eq("ET-26SEP25-CDE")
    end

    it "returns nil for unsupported assets" do
      contract_id = manager.generate_upcoming_month_contract_id("DOGE")
      expect(contract_id).to be_nil
    end
  end

  describe "#discover_upcoming_month_contract" do
    it "creates BTC upcoming month contract if it does not exist" do
      expect(TradingPair.find_by(product_id: "BIT-26SEP25-CDE")).to be_nil

      contract_id = manager.discover_upcoming_month_contract("BTC")
      expect(contract_id).to eq("BIT-26SEP25-CDE")

      trading_pair = TradingPair.find_by(product_id: "BIT-26SEP25-CDE")
      expect(trading_pair).to be_present
      expect(trading_pair.base_currency).to eq("BTC")
      expect(trading_pair.quote_currency).to eq("USD")
      expect(trading_pair.expiration_date).to eq(Date.new(2025, 9, 26))
      expect(trading_pair.contract_type).to eq("CDE")
      expect(trading_pair.enabled).to be true
    end

    it "returns existing contract ID if contract already exists" do
      # Create existing contract
      TradingPair.create!(
        product_id: "BIT-26SEP25-CDE",
        base_currency: "BTC",
        quote_currency: "USD",
        expiration_date: Date.new(2025, 9, 26),
        contract_type: "CDE",
        enabled: true
      )

      contract_id = manager.discover_upcoming_month_contract("BTC")
      expect(contract_id).to eq("BIT-26SEP25-CDE")
    end
  end

  describe "#upcoming_month_contract" do
    context "when upcoming month contract exists" do
      let!(:btc_upcoming_contract) do
        TradingPair.create!(
          product_id: "BIT-26SEP25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 9, 26),
          contract_type: "CDE",
          enabled: true
        )
      end

      it "returns the existing contract ID" do
        expect(manager.upcoming_month_contract("BTC")).to eq("BIT-26SEP25-CDE")
      end
    end

    context "when no upcoming month contract exists" do
      it "discovers and creates the contract" do
        expect(manager.upcoming_month_contract("BTC")).to eq("BIT-26SEP25-CDE")
        expect(TradingPair.find_by(product_id: "BIT-26SEP25-CDE")).to be_present
      end
    end
  end

  describe "#best_available_contract" do
    context "when current month contract is available and tradeable" do
      let!(:btc_current) do
        TradingPair.create!(
          product_id: "BIT-29AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 8, 29),
          contract_type: "CDE",
          enabled: true
        )
      end

      it "returns the current month contract" do
        expect(manager.best_available_contract("BTC")).to eq("BIT-29AUG25-CDE")
      end
    end

    context "when current month contract is not tradeable but upcoming month is" do
      before do
        # Mock Date.current to make current month contracts expire tomorrow
        allow(Date).to receive(:current).and_return(Date.new(2025, 8, 28))
      end

      let!(:btc_current) do
        TradingPair.create!(
          product_id: "BIT-29AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 8, 29),
          contract_type: "CDE",
          enabled: true
        )
      end

      let!(:btc_upcoming) do
        TradingPair.create!(
          product_id: "BIT-26SEP25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 9, 26),
          contract_type: "CDE",
          enabled: true
        )
      end

      it "returns the upcoming month contract as fallback" do
        expect(manager.best_available_contract("BTC")).to eq("BIT-26SEP25-CDE")
      end
    end

    context "when no existing contracts are found" do
      it "discovers and creates current month contract first" do
        contract_id = manager.best_available_contract("BTC")
        expect(contract_id).to eq("BIT-29AUG25-CDE")
        expect(TradingPair.find_by(product_id: "BIT-29AUG25-CDE")).to be_present
      end

      context "when current month discovery fails" do
        before do
          # Mock the contract generation to fail for current month
          allow(manager).to receive(:generate_current_month_contract_id).and_return(nil)
        end

        it "falls back to discovering upcoming month contract" do
          contract_id = manager.best_available_contract("BTC")
          expect(contract_id).to eq("BIT-26SEP25-CDE")
          expect(TradingPair.find_by(product_id: "BIT-26SEP25-CDE")).to be_present
        end
      end
    end
  end

  describe "#update_upcoming_month_contracts" do
    it "creates upcoming month contracts for BTC and ETH" do
      expect(TradingPair.find_by(product_id: "BIT-26SEP25-CDE")).to be_nil
      expect(TradingPair.find_by(product_id: "ET-26SEP25-CDE")).to be_nil

      manager.update_upcoming_month_contracts

      btc_contract = TradingPair.find_by(product_id: "BIT-26SEP25-CDE")
      eth_contract = TradingPair.find_by(product_id: "ET-26SEP25-CDE")

      expect(btc_contract).to be_present
      expect(eth_contract).to be_present
      expect(btc_contract.enabled).to be true
      expect(eth_contract.enabled).to be true
    end

    it "skips creation if contract ID generation fails" do
      # Mock contract generation to fail
      allow(manager).to receive(:generate_upcoming_month_contract_id).and_return(nil)

      manager.update_upcoming_month_contracts

      expect(TradingPair.find_by(product_id: "BIT-26SEP25-CDE")).to be_nil
      expect(TradingPair.find_by(product_id: "ET-26SEP25-CDE")).to be_nil
    end
  end

  describe "#update_all_contracts" do
    it "updates both current and upcoming month contracts" do
      expect(TradingPair.find_by(product_id: "BIT-29AUG25-CDE")).to be_nil
      expect(TradingPair.find_by(product_id: "ET-29AUG25-CDE")).to be_nil
      expect(TradingPair.find_by(product_id: "BIT-26SEP25-CDE")).to be_nil
      expect(TradingPair.find_by(product_id: "ET-26SEP25-CDE")).to be_nil

      manager.update_all_contracts

      # Check current month contracts
      btc_current = TradingPair.find_by(product_id: "BIT-29AUG25-CDE")
      eth_current = TradingPair.find_by(product_id: "ET-29AUG25-CDE")
      expect(btc_current).to be_present
      expect(eth_current).to be_present

      # Check upcoming month contracts
      btc_upcoming = TradingPair.find_by(product_id: "BIT-26SEP25-CDE")
      eth_upcoming = TradingPair.find_by(product_id: "ET-26SEP25-CDE")
      expect(btc_upcoming).to be_present
      expect(eth_upcoming).to be_present
    end
  end

  describe "#update_current_month_contracts" do
    it "creates current month contracts for BTC and ETH" do
      expect(TradingPair.find_by(product_id: "BIT-29AUG25-CDE")).to be_nil
      expect(TradingPair.find_by(product_id: "ET-29AUG25-CDE")).to be_nil

      manager.update_current_month_contracts

      btc_contract = TradingPair.find_by(product_id: "BIT-29AUG25-CDE")
      eth_contract = TradingPair.find_by(product_id: "ET-29AUG25-CDE")

      expect(btc_contract).to be_present
      expect(eth_contract).to be_present
      expect(btc_contract.enabled).to be true
      expect(eth_contract.enabled).to be true
    end

    it "disables expired contracts" do
      expired_contract = TradingPair.create!(
        product_id: "BIT-31JUL25-CDE",
        base_currency: "BTC",
        quote_currency: "USD",
        expiration_date: Date.new(2025, 7, 31),
        enabled: true
      )

      manager.update_current_month_contracts

      expired_contract.reload
      expect(expired_contract.enabled).to be false
    end
  end

  # === CONTRACT DISCOVERY AND METADATA VALIDATION ===

  describe "#generate_contract_id_for_month" do
    context "with valid inputs" do
      it "generates BTC contract ID for specific month" do
        march_date = Date.new(2025, 3, 15)
        contract_id = manager.generate_contract_id_for_month("BTC", march_date)
        expect(contract_id).to eq("BIT-28MAR25-CDE") # Last Friday of March 2025
      end

      it "generates ETH contract ID for specific month" do
        december_date = Date.new(2025, 12, 10)
        contract_id = manager.generate_contract_id_for_month("ETH", december_date)
        expect(contract_id).to eq("ET-26DEC25-CDE") # Last Friday of December 2025
      end

      it "handles edge case where last Friday is very early in month" do
        # February 2025 - last Friday is Feb 28th
        feb_date = Date.new(2025, 2, 10)
        contract_id = manager.generate_contract_id_for_month("BTC", feb_date)
        expect(contract_id).to eq("BIT-28FEB25-CDE")
      end

      it "handles months with different Friday patterns" do
        # June 2025 - last Friday is June 27th
        june_date = Date.new(2025, 6, 15)
        contract_id = manager.generate_contract_id_for_month("ETH", june_date)
        expect(contract_id).to eq("ET-27JUN25-CDE")
      end
    end

    context "with invalid inputs" do
      it "returns nil for unsupported asset" do
        contract_id = manager.generate_contract_id_for_month("INVALID", Date.current)
        expect(contract_id).to be_nil
      end

      it "returns nil for nil asset" do
        contract_id = manager.generate_contract_id_for_month(nil, Date.current)
        expect(contract_id).to be_nil
      end

      it "handles case-insensitive asset names" do
        contract_id = manager.generate_contract_id_for_month("btc", current_date)
        expect(contract_id).to eq("BIT-29AUG25-CDE")
      end
    end

    context "edge case months" do
      it "handles month where no Friday exists before beginning_of_month (safety check)" do
        # This is a theoretical edge case - testing the safety break
        # Mock a scenario where we might hit the safety check
        jan_date = Date.new(2025, 1, 1)
        contract_id = manager.generate_contract_id_for_month("BTC", jan_date)
        expect(contract_id).to match(/BIT-\d{2}JAN25-CDE/)
      end
    end
  end

  # === ERROR HANDLING AND EDGE CASES ===

  describe "error handling in discovery methods" do
    let(:logger) { instance_double(Logger) }
    let(:manager_with_logger) { described_class.new(logger: logger) }

    before do
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
    end

    describe "#discover_current_month_contract" do
      it "returns nil when contract ID generation fails" do
        allow(manager_with_logger).to receive(:generate_current_month_contract_id).and_return(nil)

        result = manager_with_logger.discover_current_month_contract("BTC")
        expect(result).to be_nil
      end

      it "returns nil when contract info parsing fails" do
        allow(TradingPair).to receive(:parse_contract_info).and_return(nil)

        result = manager_with_logger.discover_current_month_contract("BTC")
        expect(result).to be_nil
      end

      it "returns nil and logs error when trading pair save fails" do
        # Create an invalid trading pair that will fail validation
        invalid_pair = TradingPair.new
        allow(TradingPair).to receive(:find_or_initialize_by).and_return(invalid_pair)
        allow(invalid_pair).to receive(:assign_attributes)
        allow(invalid_pair).to receive(:save).and_return(false)
        allow(invalid_pair).to receive(:errors).and_return(
          double(full_messages: ["Product ID can't be blank"])
        )

        expect(logger).to receive(:error).with(
          "Failed to create contract BIT-29AUG25-CDE: [\"Product ID can't be blank\"]"
        )

        result = manager_with_logger.discover_current_month_contract("BTC")
        expect(result).to be_nil
      end
    end

    describe "#discover_upcoming_month_contract" do
      it "returns nil when contract ID generation fails" do
        allow(manager_with_logger).to receive(:generate_upcoming_month_contract_id).and_return(nil)

        result = manager_with_logger.discover_upcoming_month_contract("BTC")
        expect(result).to be_nil
      end

      it "returns nil when contract info parsing fails" do
        allow(TradingPair).to receive(:parse_contract_info).and_return(nil)

        result = manager_with_logger.discover_upcoming_month_contract("BTC")
        expect(result).to be_nil
      end

      it "returns nil and logs error when trading pair save fails" do
        invalid_pair = TradingPair.new
        allow(TradingPair).to receive(:find_or_initialize_by).and_return(invalid_pair)
        allow(invalid_pair).to receive(:assign_attributes)
        allow(invalid_pair).to receive(:save).and_return(false)
        allow(invalid_pair).to receive(:errors).and_return(
          double(full_messages: ["Product ID can't be blank"])
        )

        expect(logger).to receive(:error).with(
          "Failed to create upcoming month contract BIT-26SEP25-CDE: [\"Product ID can't be blank\"]"
        )

        result = manager_with_logger.discover_upcoming_month_contract("BTC")
        expect(result).to be_nil
      end
    end
  end

  # === CONTRACT VALIDATION AND BUSINESS RULES ===

  describe "contract validation and business rules" do
    describe "asset mapping validation" do
      it "supports BTC to BIT mapping" do
        expect(described_class::ASSET_MAPPING["BTC"]).to eq("BIT")
      end

      it "supports ETH to ET mapping" do
        expect(described_class::ASSET_MAPPING["ETH"]).to eq("ET")
      end

      it "freezes the asset mapping constant" do
        expect(described_class::ASSET_MAPPING).to be_frozen
      end

      it "handles case sensitivity correctly" do
        contract_id = manager.generate_current_month_contract_id("btc")
        expect(contract_id).to eq("BIT-29AUG25-CDE")
      end
    end

    describe "contract expiration date validation" do
      it "ensures expiration dates are always last Friday of month" do
        # Test multiple months to ensure consistency
        test_months = [
          Date.new(2025, 1, 15),
          Date.new(2025, 4, 10),
          Date.new(2025, 7, 20),
          Date.new(2025, 10, 5)
        ]

        test_months.each do |month_date|
          contract_id = manager.generate_contract_id_for_month("BTC", month_date)

          # Parse the date from the contract ID
          match = contract_id.match(/-(\d{2}[A-Z]{3}\d{2})-/)
          date_str = match[1]
          parsed_date = Date.strptime(date_str, "%d%b%y")

          # Verify it's a Friday
          expect(parsed_date.friday?).to be true

          # Verify it's in the correct month
          expect(parsed_date.month).to eq(month_date.month)
          expect(parsed_date.year).to eq(month_date.year)

          # Verify it's the last Friday
          next_friday = parsed_date + 7.days
          expect(next_friday.month).not_to eq(month_date.month)
        end
      end
    end

    describe "contract status management" do
      it "sets correct default attributes for new contracts" do
        contract_id = manager.discover_current_month_contract("BTC")
        trading_pair = TradingPair.find_by(product_id: contract_id)

        expect(trading_pair.enabled).to be true
        expect(trading_pair.status).to eq("online")
        expect(trading_pair.base_currency).to eq("BTC")
        expect(trading_pair.quote_currency).to eq("USD")
        expect(trading_pair.contract_type).to eq("CDE")
      end
    end
  end

  # === INTEGRATION AND LIFECYCLE MANAGEMENT ===

  describe "contract lifecycle management" do
    describe "#expiring_contracts with various scenarios" do
      let!(:expiring_today) {
        TradingPair.create!(
          product_id: "BIT-15AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: current_date,
          enabled: true
        )
      }
      let!(:expiring_tomorrow) {
        TradingPair.create!(
          product_id: "BIT-16AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: current_date + 1.day,
          enabled: true
        )
      }
      let!(:disabled_expiring) {
        TradingPair.create!(
          product_id: "BIT-17AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: current_date + 2.days,
          enabled: false
        )
      }
      let!(:expired_yesterday) {
        TradingPair.create!(
          product_id: "BIT-14AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: current_date - 1.day,
          enabled: true
        )
      }

      it "excludes contracts expiring today" do
        expiring = manager.expiring_contracts(days_ahead: 5)
        expect(expiring).not_to include(expiring_today)
      end

      it "excludes already expired contracts" do
        expiring = manager.expiring_contracts(days_ahead: 5)
        expect(expiring).not_to include(expired_yesterday)
      end

      it "excludes disabled contracts" do
        expiring = manager.expiring_contracts(days_ahead: 5)
        expect(expiring).not_to include(disabled_expiring)
      end

      it "includes only enabled contracts expiring in the future within range" do
        expiring = manager.expiring_contracts(days_ahead: 2)
        expect(expiring).to contain_exactly(expiring_tomorrow)
      end
    end

    describe "#rollover_needed? edge cases" do
      it "returns false when no contracts exist" do
        expect(manager.rollover_needed?).to be false
      end

      it "returns false with custom days_before_expiry" do
        expect(manager.rollover_needed?(days_before_expiry: 1)).to be false
      end

      it "returns true when contracts expire exactly on the threshold" do
        TradingPair.create!(
          product_id: "BIT-18AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: current_date + 3.days,
          enabled: true
        )

        expect(manager.rollover_needed?(days_before_expiry: 3)).to be true
      end
    end
  end

  # === LOGGING AND INSTRUMENTATION ===

  describe "logging behavior" do
    let(:logger) { instance_double(Logger) }
    let(:manager_with_logger) { described_class.new(logger: logger) }

    before do
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
    end

    describe "successful operations logging" do
      it "logs successful contract creation" do
        expect(logger).to receive(:info).with("Created current month contract: BIT-29AUG25-CDE")

        manager_with_logger.discover_current_month_contract("BTC")
      end

      it "logs contract updates during asset processing" do
        expect(logger).to receive(:info).with("Updating current month contracts for BTC")
        expect(logger).to receive(:info).with("Current month contract for BTC: BIT-29AUG25-CDE")
        expect(logger).to receive(:info).with("Updating current month contracts for ETH")
        expect(logger).to receive(:info).with("Current month contract for ETH: ET-29AUG25-CDE")

        manager_with_logger.update_current_month_contracts
      end

      it "logs warning when contract discovery fails" do
        # Mock contract discovery to fail for testing warning path
        allow(manager_with_logger).to receive(:discover_current_month_contract).and_return(nil)

        expect(logger).to receive(:warn).with("Could not discover current month contract for BTC")

        # Call the private method to trigger the warning
        manager_with_logger.send(:update_contracts_for_asset, "BTC", current_date)
      end
    end

    describe "warning and error logging" do
      it "logs warning when contract discovery fails" do
        allow(manager_with_logger).to receive(:discover_current_month_contract).and_return(nil)

        expect(logger).to receive(:warn).with("Could not discover current month contract for BTC")
        expect(logger).to receive(:warn).with("Could not discover current month contract for ETH")

        manager_with_logger.update_current_month_contracts
      end
    end
  end

  # === INITIALIZATION AND CONFIGURATION ===

  describe "initialization" do
    it "accepts custom logger" do
      custom_logger = Logger.new($stdout)
      custom_manager = described_class.new(logger: custom_logger)

      expect(custom_manager.instance_variable_get(:@logger)).to eq(custom_logger)
    end

    it "defaults to Rails.logger when no logger provided" do
      default_manager = described_class.new

      expect(default_manager.instance_variable_get(:@logger)).to eq(Rails.logger)
    end
  end

  # === INTEGRATION WITH TRADING_PAIR MODEL ===

  describe "TradingPair integration" do
    describe "scope interactions" do
      let!(:active_current) {
        TradingPair.create!(
          product_id: "BIT-29AUG25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 8, 29),
          enabled: true
        )
      }
      let!(:active_upcoming) {
        TradingPair.create!(
          product_id: "BIT-26SEP25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 9, 26),
          enabled: true
        )
      }
      let!(:disabled_contract) {
        TradingPair.create!(
          product_id: "BIT-31DEC25-CDE",
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 12, 31),
          enabled: false
        )
      }

      it "interacts correctly with TradingPair.current_month_for_asset" do
        contracts = TradingPair.current_month_for_asset("BTC")
        expect(contracts).to contain_exactly(active_current)
      end

      it "interacts correctly with TradingPair.upcoming_month_for_asset" do
        contracts = TradingPair.upcoming_month_for_asset("BTC")
        expect(contracts).to contain_exactly(active_upcoming)
      end

      it "interacts correctly with TradingPair.best_available_for_asset" do
        best_contract = TradingPair.best_available_for_asset("BTC")
        expect(best_contract).to eq(active_current)
      end
    end

    describe "contract info parsing integration" do
      it "correctly utilizes TradingPair.parse_contract_info" do
        # This tests the integration between the manager and the model
        contract_id = manager.discover_current_month_contract("BTC")
        trading_pair = TradingPair.find_by(product_id: contract_id)

        parsed_info = TradingPair.parse_contract_info(contract_id)

        expect(trading_pair.base_currency).to eq(parsed_info[:base_currency])
        expect(trading_pair.quote_currency).to eq(parsed_info[:quote_currency])
        expect(trading_pair.expiration_date).to eq(parsed_info[:expiration_date])
        expect(trading_pair.contract_type).to eq(parsed_info[:contract_type])
      end
    end
  end
end
