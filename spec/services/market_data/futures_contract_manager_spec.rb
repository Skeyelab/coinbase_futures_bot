# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketData::FuturesContractManager, type: :service do
  let(:manager) { described_class.new }
  let(:current_date) { Date.new(2025, 8, 15) } # Mid-August 2025

  before do
    # Mock Date.current to return a fixed date for testing
    allow(Date).to receive(:current).and_return(current_date)
  end

  describe '#generate_current_month_contract_id' do
    it 'generates BTC contract ID for current month' do
      # Mock finding the last Friday of August 2025 (which would be August 29th, 2025)
      contract_id = manager.generate_current_month_contract_id('BTC')
      expect(contract_id).to eq('BIT-29AUG25-CDE')
    end

    it 'generates ETH contract ID for current month' do
      contract_id = manager.generate_current_month_contract_id('ETH')
      expect(contract_id).to eq('ET-29AUG25-CDE')
    end

    it 'returns nil for unsupported assets' do
      contract_id = manager.generate_current_month_contract_id('DOGE')
      expect(contract_id).to be_nil
    end
  end

  describe '#discover_current_month_contract' do
    it 'creates BTC current month contract if it does not exist' do
      expect(TradingPair.find_by(product_id: 'BIT-29AUG25-CDE')).to be_nil

      contract_id = manager.discover_current_month_contract('BTC')
      expect(contract_id).to eq('BIT-29AUG25-CDE')

      trading_pair = TradingPair.find_by(product_id: 'BIT-29AUG25-CDE')
      expect(trading_pair).to be_present
              expect(trading_pair.base_currency).to eq('BTC')
        expect(trading_pair.quote_currency).to eq('USD')
        expect(trading_pair.expiration_date).to eq(Date.new(2025, 8, 29))
        expect(trading_pair.contract_type).to eq('CDE')
        expect(trading_pair.enabled).to be true
    end

    it 'returns existing contract ID if contract already exists' do
      # Create existing contract
      TradingPair.create!(
        product_id: 'BIT-29AUG25-CDE',
        base_currency: 'BTC',
        quote_currency: 'USD',
        expiration_date: Date.new(2025, 8, 29),
        contract_type: 'CDE',
        enabled: true
      )

      contract_id = manager.discover_current_month_contract('BTC')
      expect(contract_id).to eq('BIT-29AUG25-CDE')
    end
  end

  describe '#current_month_contract' do
    context 'when current month contract exists' do
      let!(:btc_contract) do
        TradingPair.create!(
          product_id: 'BIT-29AUG25-CDE',
          base_currency: 'BTC',
          quote_currency: 'USD',
          expiration_date: Date.new(2025, 8, 29),
          contract_type: 'CDE',
          enabled: true
        )
      end

      it 'returns the existing contract ID' do
        expect(manager.current_month_contract('BTC')).to eq('BIT-29AUG25-CDE')
      end
    end

    context 'when no current month contract exists' do
      it 'discovers and creates the contract' do
        expect(manager.current_month_contract('BTC')).to eq('BIT-29AUG25-CDE')
        expect(TradingPair.find_by(product_id: 'BIT-29AUG25-CDE')).to be_present
      end
    end
  end

  describe '#active_futures_contracts' do
    let!(:btc_current) { TradingPair.create!(product_id: 'BIT-29AUG25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 8, 29), enabled: true) }
    let!(:eth_current) { TradingPair.create!(product_id: 'ET-29AUG25-CDE', base_currency: 'ETH', quote_currency: 'USD', expiration_date: Date.new(2025, 8, 29), enabled: true) }
    let!(:btc_next) { TradingPair.create!(product_id: 'BIT-30SEP25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 9, 30), enabled: true) }
    let!(:expired_contract) { TradingPair.create!(product_id: 'BIT-31JUL25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 7, 31), enabled: true) }
    let!(:disabled_contract) { TradingPair.create!(product_id: 'BIT-31DEC25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 12, 31), enabled: false) }

    it 'returns only active, non-expired futures contracts' do
      active_contracts = manager.active_futures_contracts
      expect(active_contracts).to contain_exactly(btc_current, eth_current, btc_next)
      expect(active_contracts).not_to include(expired_contract, disabled_contract)
    end
  end

  describe '#expiring_contracts' do
    let!(:expiring_soon) { TradingPair.create!(product_id: 'BIT-17AUG25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 8, 17), enabled: true) }
    let!(:expiring_later) { TradingPair.create!(product_id: 'BIT-29AUG25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 8, 29), enabled: true) }
    let!(:expiring_next_month) { TradingPair.create!(product_id: 'BIT-30SEP25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 9, 30), enabled: true) }

    it 'returns contracts expiring within specified days' do
      # Test with 7 days ahead (default)
      expiring = manager.expiring_contracts
      expect(expiring).to contain_exactly(expiring_soon)
    end

    it 'returns contracts expiring within custom days ahead' do
      # Test with 20 days ahead
      expiring = manager.expiring_contracts(days_ahead: 20)
      expect(expiring).to contain_exactly(expiring_soon, expiring_later)
    end
  end

  describe '#rollover_needed?' do
    context 'when contracts are expiring soon' do
      let!(:expiring_soon) { TradingPair.create!(product_id: 'BIT-17AUG25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 8, 17), enabled: true) }

      it 'returns true' do
        expect(manager.rollover_needed?).to be true
      end
    end

    context 'when no contracts are expiring soon' do
      let!(:expiring_later) { TradingPair.create!(product_id: 'BIT-30SEP25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 9, 30), enabled: true) }

      it 'returns false' do
        expect(manager.rollover_needed?).to be false
      end
    end
  end

  describe '#update_current_month_contracts' do
    it 'creates current month contracts for BTC and ETH' do
      expect(TradingPair.find_by(product_id: 'BIT-29AUG25-CDE')).to be_nil
      expect(TradingPair.find_by(product_id: 'ET-29AUG25-CDE')).to be_nil

      manager.update_current_month_contracts

      btc_contract = TradingPair.find_by(product_id: 'BIT-29AUG25-CDE')
      eth_contract = TradingPair.find_by(product_id: 'ET-29AUG25-CDE')

      expect(btc_contract).to be_present
      expect(eth_contract).to be_present
      expect(btc_contract.enabled).to be true
      expect(eth_contract.enabled).to be true
    end

    it 'disables expired contracts' do
      expired_contract = TradingPair.create!(
        product_id: 'BIT-31JUL25-CDE',
        base_currency: 'BTC',
        quote_currency: 'USD',
        expiration_date: Date.new(2025, 7, 31),
        enabled: true
      )

      manager.update_current_month_contracts

      expired_contract.reload
      expect(expired_contract.enabled).to be false
    end
  end
end
