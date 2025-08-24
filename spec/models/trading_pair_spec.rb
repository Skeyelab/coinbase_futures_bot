# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TradingPair, type: :model do
  let(:current_date) { Date.new(2025, 8, 15) } # Mid-August 2025

  before do
    # Mock Date.current to return a fixed date for testing
    allow(Date).to receive(:current).and_return(current_date)
  end

  describe 'validations' do
    it 'validates presence and uniqueness of product_id' do
      pair = TradingPair.create!(product_id: 'BTC-USD', base_currency: 'BTC', quote_currency: 'USD')
      expect(pair).to be_valid

      duplicate = TradingPair.new(product_id: 'BTC-USD', base_currency: 'BTC', quote_currency: 'USD')
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:product_id]).to include('has already been taken')
    end
  end

  describe 'scopes' do
    let!(:btc_current_month) { TradingPair.create!(product_id: 'BIT-29AUG25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 8, 29), enabled: true) }
    let!(:eth_current_month) { TradingPair.create!(product_id: 'ET-29AUG25-CDE', base_currency: 'ETH', quote_currency: 'USD', expiration_date: Date.new(2025, 8, 29), enabled: true) }
    let!(:btc_next_month) { TradingPair.create!(product_id: 'BIT-30SEP25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 9, 30), enabled: true) }
    let!(:expired_contract) { TradingPair.create!(product_id: 'BIT-31JUL25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 7, 31), enabled: true) }

    describe '.active' do
      it 'returns only enabled and non-expired contracts' do
        active = TradingPair.active
        expect(active).to include(btc_current_month, eth_current_month, btc_next_month)
        expect(active).not_to include(expired_contract)
      end
    end

    describe '.current_month' do
      it 'returns contracts expiring in the current month' do
        expect(TradingPair.current_month).to contain_exactly(btc_current_month, eth_current_month)
      end
    end

    describe '.not_expired' do
      it 'returns contracts that have not expired' do
        not_expired = TradingPair.not_expired
        expect(not_expired).to include(btc_current_month, eth_current_month, btc_next_month)
        expect(not_expired).not_to include(expired_contract)
      end
    end

    describe '.current_month_for_asset' do
      it 'returns current month contracts for BTC' do
        expect(TradingPair.current_month_for_asset('BTC')).to contain_exactly(btc_current_month)
      end

      it 'returns current month contracts for ETH' do
        expect(TradingPair.current_month_for_asset('ETH')).to contain_exactly(eth_current_month)
      end

      it 'returns empty for assets with no current month contracts' do
        expect(TradingPair.current_month_for_asset('DOGE')).to be_empty
      end
    end
  end

  describe '.parse_contract_info' do
    it 'parses BTC current month contract' do
      info = TradingPair.parse_contract_info('BIT-29AUG25-CDE')
      expect(info).to eq({
        base_currency: 'BTC',
        quote_currency: 'USD',
        expiration_date: Date.new(2025, 8, 29),
        contract_type: 'CDE'
      })
    end

    it 'parses ETH current month contract' do
      info = TradingPair.parse_contract_info('ET-29AUG25-CDE')
      expect(info).to eq({
        base_currency: 'ETH',
        quote_currency: 'USD',
        expiration_date: Date.new(2025, 8, 29),
        contract_type: 'CDE'
      })
    end

    it 'returns nil for invalid format' do
      expect(TradingPair.parse_contract_info('BTC-USD')).to be_nil
      expect(TradingPair.parse_contract_info('invalid')).to be_nil
      expect(TradingPair.parse_contract_info(nil)).to be_nil
    end

    it 'handles different date formats' do
      info = TradingPair.parse_contract_info('BIT-30SEP25-CDE')
      expect(info[:expiration_date]).to eq(Date.new(2025, 9, 30))
    end
  end

  describe 'instance methods' do
    let(:current_month_contract) { TradingPair.create!(product_id: 'BIT-29AUG25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 8, 29)) }
    let(:expired_contract) { TradingPair.create!(product_id: 'BIT-31JUL25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 7, 31)) }
    let(:next_month_contract) { TradingPair.create!(product_id: 'BIT-30SEP25-CDE', base_currency: 'BTC', quote_currency: 'USD', expiration_date: Date.new(2025, 9, 30)) }

    describe '#expired?' do
      it 'returns false for current month contracts' do
        expect(current_month_contract.expired?).to be false
      end

      it 'returns true for expired contracts' do
        expect(expired_contract.expired?).to be true
      end

      it 'returns false for future contracts' do
        expect(next_month_contract.expired?).to be false
      end
    end

    describe '#current_month?' do
      it 'returns true for current month contracts' do
        expect(current_month_contract.current_month?).to be true
      end

      it 'returns false for expired contracts' do
        expect(expired_contract.current_month?).to be false
      end

      it 'returns false for next month contracts' do
        expect(next_month_contract.current_month?).to be false
      end
    end

    describe '#underlying_asset' do
      it 'returns parsed asset for futures contracts' do
        expect(current_month_contract.underlying_asset).to eq('BTC')
      end
    end
  end
end
