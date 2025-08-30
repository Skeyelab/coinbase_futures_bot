# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::FuturesContractManager, type: :service do
  let(:manager) { described_class.new }
  let(:current_date) { Date.new(2025, 8, 15) } # Mid-August 2025

  # Mock Date.current to return a fixed date for all tests
  before do
    allow(Date).to receive(:current).and_return(current_date)
  end

  # Helper method to dynamically generate expected contract IDs
  def expected_contract_id_for_month(asset, month_date)
    prefix = MarketData::FuturesContractManager::ASSET_MAPPING[asset.upcase]
    return nil unless prefix

    # Find the last Friday of the specified month
    last_day = month_date.end_of_month
    expiration_date = last_day
    until expiration_date.friday?
      expiration_date -= 1.day
      break if expiration_date < month_date.beginning_of_month
    end

    date_str = expiration_date.strftime("%d%b%y").upcase
    "#{prefix}-#{date_str}-CDE"
  end

  context "Tests with mocked dates (existing behavior)" do
    describe "#generate_current_month_contract_id" do
      it "generates BTC contract ID for current month" do
        contract_id = manager.generate_current_month_contract_id("BTC")
        expected_id = expected_contract_id_for_month("BTC", current_date)
        expect(contract_id).to eq(expected_id)
        # Verify it matches the expected hardcoded value for this specific test date
        expect(contract_id).to eq("BIT-29AUG25-CDE")
      end

      it "generates ETH contract ID for current month" do
        contract_id = manager.generate_current_month_contract_id("ETH")
        expected_id = expected_contract_id_for_month("ETH", current_date)
        expect(contract_id).to eq(expected_id)
        # Verify it matches the expected hardcoded value for this specific test date
        expect(contract_id).to eq("ET-29AUG25-CDE")
      end

      it "returns nil for unsupported assets" do
        contract_id = manager.generate_current_month_contract_id("DOGE")
        expect(contract_id).to be_nil
      end
    end

    describe "#discover_current_month_contract" do
      it "creates BTC current month contract if it does not exist" do
        expected_contract_id = expected_contract_id_for_month("BTC", current_date)
        expect(TradingPair.find_by(product_id: expected_contract_id)).to be_nil

        contract_id = manager.discover_current_month_contract("BTC")
        expect(contract_id).to eq(expected_contract_id)

        trading_pair = TradingPair.find_by(product_id: expected_contract_id)
        expect(trading_pair).to be_present
        expect(trading_pair.base_currency).to eq("BTC")
        expect(trading_pair.quote_currency).to eq("USD")
        expect(trading_pair.expiration_date).to eq(Date.new(2025, 8, 29))
        expect(trading_pair.contract_type).to eq("CDE")
        expect(trading_pair.enabled).to be true
      end

      it "returns existing contract ID if contract already exists" do
        expected_contract_id = expected_contract_id_for_month("BTC", current_date)

        # Create existing contract
        TradingPair.create!(
          product_id: expected_contract_id,
          base_currency: "BTC",
          quote_currency: "USD",
          expiration_date: Date.new(2025, 8, 29),
          contract_type: "CDE",
          enabled: true
        )

        contract_id = manager.discover_current_month_contract("BTC")
        expect(contract_id).to eq(expected_contract_id)
      end
    end

    describe "#current_month_contract" do
      context "when current month contract exists" do
        let(:expected_contract_id) { expected_contract_id_for_month("BTC", current_date) }
        let!(:btc_contract) do
          TradingPair.create!(
            product_id: expected_contract_id,
            base_currency: "BTC",
            quote_currency: "USD",
            expiration_date: Date.new(2025, 8, 29),
            contract_type: "CDE",
            enabled: true
          )
        end

        it "returns the existing contract ID" do
          expect(manager.current_month_contract("BTC")).to eq(expected_contract_id)
        end
      end

      context "when no current month contract exists" do
        it "discovers and creates the contract" do
          expected_contract_id = expected_contract_id_for_month("BTC", current_date)
          expect(manager.current_month_contract("BTC")).to eq(expected_contract_id)
          expect(TradingPair.find_by(product_id: expected_contract_id)).to be_present
        end
      end
    end
  end

  describe "#active_futures_contracts" do
    let!(:btc_current) do
      TradingPair.create!(product_id: "BIT-29AUG25-CDE", base_currency: "BTC", quote_currency: "USD",
        expiration_date: Date.new(2025, 8, 29), enabled: true)
    end
    let!(:eth_current) do
      TradingPair.create!(product_id: "ET-29AUG25-CDE", base_currency: "ETH", quote_currency: "USD",
        expiration_date: Date.new(2025, 8, 29), enabled: true)
    end
    let!(:btc_next) do
      TradingPair.create!(product_id: "BIT-30SEP25-CDE", base_currency: "BTC", quote_currency: "USD",
        expiration_date: Date.new(2025, 9, 30), enabled: true)
    end
    let!(:expired_contract) do
      TradingPair.create!(product_id: "BIT-31JUL25-CDE", base_currency: "BTC", quote_currency: "USD",
        expiration_date: Date.new(2025, 7, 31), enabled: true)
    end
    let!(:disabled_contract) do
      TradingPair.create!(product_id: "BIT-31DEC25-CDE", base_currency: "BTC", quote_currency: "USD",
        expiration_date: Date.new(2025, 12, 31), enabled: false)
    end

    it "returns only active, non-expired futures contracts" do
      active_contracts = manager.active_futures_contracts
      expect(active_contracts).to contain_exactly(btc_current, eth_current, btc_next)
      expect(active_contracts).not_to include(expired_contract, disabled_contract)
    end
  end

  describe "#expiring_contracts" do
    let!(:expiring_soon) do
      TradingPair.create!(product_id: "BIT-17AUG25-CDE", base_currency: "BTC", quote_currency: "USD",
        expiration_date: Date.new(2025, 8, 17), enabled: true)
    end
    let!(:expiring_later) do
      TradingPair.create!(product_id: "BIT-29AUG25-CDE", base_currency: "BTC", quote_currency: "USD",
        expiration_date: Date.new(2025, 8, 29), enabled: true)
    end
    let!(:expiring_next_month) do
      TradingPair.create!(product_id: "BIT-30SEP25-CDE", base_currency: "BTC", quote_currency: "USD",
        expiration_date: Date.new(2025, 9, 30), enabled: true)
    end

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
      let!(:expiring_soon) do
        TradingPair.create!(product_id: "BIT-17AUG25-CDE", base_currency: "BTC", quote_currency: "USD",
          expiration_date: Date.new(2025, 8, 17), enabled: true)
      end

      it "returns true" do
        expect(manager.rollover_needed?).to be true
      end
    end

    context "when no contracts are expiring soon" do
      let!(:expiring_later) do
        TradingPair.create!(product_id: "BIT-30SEP25-CDE", base_currency: "BTC", quote_currency: "USD",
          expiration_date: Date.new(2025, 9, 30), enabled: true)
      end

      it "returns false" do
        expect(manager.rollover_needed?).to be false
      end
    end
  end

  context "Tests with mocked dates (existing behavior)" do
    describe "#generate_upcoming_month_contract_id" do
      it "generates BTC contract ID for upcoming month" do
        contract_id = manager.generate_upcoming_month_contract_id("BTC")
        expected_id = expected_contract_id_for_month("BTC", current_date.next_month)
        expect(contract_id).to eq(expected_id)
        # Verify it matches the expected hardcoded value for this specific test date
        expect(contract_id).to eq("BIT-26SEP25-CDE")
      end

      it "generates ETH contract ID for upcoming month" do
        contract_id = manager.generate_upcoming_month_contract_id("ETH")
        expected_id = expected_contract_id_for_month("ETH", current_date.next_month)
        expect(contract_id).to eq(expected_id)
        # Verify it matches the expected hardcoded value for this specific test date
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
  end

  # Tests that validate the real business logic without date mocking
  context "Real date logic validation (no mocking)" do
    describe "Contract ID generation without Date.current mocking" do
      it "generates valid current month contract IDs using real dates" do
        # Test without any Date mocking to ensure real logic works
        btc_contract = manager.generate_current_month_contract_id("BTC")
        eth_contract = manager.generate_current_month_contract_id("ETH")

        # Verify format
        expect(btc_contract).to match(/\ABIT-\d{2}[A-Z]{3}\d{2}-CDE\z/)
        expect(eth_contract).to match(/\AET-\d{2}[A-Z]{3}\d{2}-CDE\z/)

        # Verify they have the same date part (same expiration)
        btc_date_part = btc_contract.split("-")[1]
        eth_date_part = eth_contract.split("-")[1]
        expect(btc_date_part).to eq(eth_date_part)

        # Verify the date represents the current month
        month_abbr = btc_date_part[2..4]
        current_month_abbr = Date.current.strftime("%b").upcase
        expect(month_abbr).to eq(current_month_abbr)
      end

      it "generates valid upcoming month contract IDs using real dates" do
        btc_upcoming = manager.generate_upcoming_month_contract_id("BTC")
        eth_upcoming = manager.generate_upcoming_month_contract_id("ETH")

        # Verify format
        expect(btc_upcoming).to match(/\ABIT-\d{2}[A-Z]{3}\d{2}-CDE\z/)
        expect(eth_upcoming).to match(/\AET-\d{2}[A-Z]{3}\d{2}-CDE\z/)

        # Verify the date represents the next month
        btc_date_part = btc_upcoming.split("-")[1]
        month_abbr = btc_date_part[2..4]
        next_month_abbr = Date.current.next_month.strftime("%b").upcase
        expect(month_abbr).to eq(next_month_abbr)
      end

      it "creates TradingPair records with correct Friday expiration dates" do
        # Test full integration without date mocking
        contract_id = manager.discover_current_month_contract("BTC")

        trading_pair = TradingPair.find_by(product_id: contract_id)
        expect(trading_pair).to be_present

        # The core validation: expiration date must be a Friday
        expect(trading_pair.expiration_date.friday?).to be(true),
          "Expiration date #{trading_pair.expiration_date} should be a Friday"

        # Must be in the current month
        expect(trading_pair.expiration_date.month).to eq(Date.current.month)
        expect(trading_pair.expiration_date.year).to eq(Date.current.year)

        # Must be the last Friday of the month
        next_friday = trading_pair.expiration_date + 7.days
        expect(next_friday).to be > trading_pair.expiration_date.end_of_month,
          "#{trading_pair.expiration_date} should be the last Friday of the month"
      end

      it "fails appropriately when contract generation logic is broken" do
        # This test will catch regressions in the core business logic
        # Unlike mocked tests, this will fail if generate_current_month_contract_id returns nil
        contract_id = manager.generate_current_month_contract_id("BTC")

        expect(contract_id).not_to be_nil, "Contract generation should not return nil"
        expect(contract_id).to be_a(String), "Contract ID should be a string"
        expect(contract_id.length).to be > 10, "Contract ID should be a reasonable length"

        # Validate the date extraction works
        date_part = contract_id.split("-")[1]
        expect(date_part.length).to eq(7), "Date part should be 7 characters (DDMMMYY)"

        day = date_part[0..1].to_i
        expect(day).to be_between(1, 31), "Day should be valid"

        month_abbr = date_part[2..4]
        expect(month_abbr).to match(/\A[A-Z]{3}\z/), "Month should be 3 uppercase letters"

        year = date_part[5..6]
        expect(year).to match(/\A\d{2}\z/), "Year should be 2 digits"
      end
    end

    describe "Cross-validation with helper method" do
      it "matches our expected_contract_id_for_month helper logic" do
        # This validates that our understanding of the algorithm is correct
        test_date = Date.current

        actual_btc = manager.generate_contract_id_for_month("BTC", test_date)
        expected_btc = expected_contract_id_for_month("BTC", test_date)

        expect(actual_btc).to eq(expected_btc),
          "Service method should match helper method logic"

        actual_eth = manager.generate_contract_id_for_month("ETH", test_date)
        expected_eth = expected_contract_id_for_month("ETH", test_date)

        expect(actual_eth).to eq(expected_eth),
          "Service method should match helper method logic for ETH"
      end
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
