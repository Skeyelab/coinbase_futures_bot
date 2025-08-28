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
end
