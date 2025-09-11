# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Trading::SwingPositionManager, type: :service do
  let(:logger) { instance_double(Logger) }
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:manager) { described_class.new(logger: logger) }

  before do
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(positions_service).to receive(:instance_variable_get).with(:@authenticated).and_return(true)
  end

  describe '#initialize' do
    it 'initializes with default logger and services' do
      expect(described_class.new).to be_a(described_class)
    end

    it 'uses custom logger when provided' do
      custom_logger = double('logger')
      manager = described_class.new(logger: custom_logger)
      expect(manager.instance_variable_get(:@logger)).to eq(custom_logger)
    end
  end

  describe '#positions_approaching_expiry' do
    let!(:trading_pair) { create(:trading_pair, product_id: 'BTC-USD-PERP', expiry_date: 3.days.from_now) }
    let!(:swing_position) { create(:position, product_id: 'BTC-USD-PERP', day_trading: false, status: 'OPEN') }
    let!(:day_position) { create(:position, product_id: 'BTC-USD-PERP', day_trading: true, status: 'OPEN') }

    it 'returns swing positions approaching expiry within buffer days' do
      # Mock config with 2 day buffer (position expires in 3 days, so within buffer)
      allow(Rails.application.config).to receive(:swing_trading_config).and_return({expiry_buffer_days: 4})
      
      result = manager.positions_approaching_expiry
      expect(result).to include(swing_position)
      expect(result).not_to include(day_position)
    end

    it 'excludes positions not approaching expiry' do
      allow(Rails.application.config).to receive(:swing_trading_config).and_return({expiry_buffer_days: 1})
      
      result = manager.positions_approaching_expiry
      expect(result).to be_empty
    end

    it 'handles positions without trading pairs' do
      swing_position.update!(product_id: 'UNKNOWN-PERP')
      result = manager.positions_approaching_expiry
      expect(result).to be_empty
    end
  end

  describe '#positions_exceeding_max_hold' do
    let!(:old_swing_position) { create(:position, day_trading: false, status: 'OPEN', entry_time: 6.days.ago) }
    let!(:new_swing_position) { create(:position, day_trading: false, status: 'OPEN', entry_time: 1.day.ago) }
    let!(:old_day_position) { create(:position, day_trading: true, status: 'OPEN', entry_time: 6.days.ago) }

    it 'returns swing positions exceeding max hold days' do
      allow(Rails.application.config).to receive(:swing_trading_config).and_return({max_hold_days: 5})
      
      result = manager.positions_exceeding_max_hold
      expect(result).to include(old_swing_position)
      expect(result).not_to include(new_swing_position)
      expect(result).not_to include(old_day_position)
    end
  end

  describe '#check_swing_tp_sl_triggers' do
    let!(:long_position) { create(:position, side: 'LONG', entry_price: 50000, take_profit: 51000, stop_loss: 49000, day_trading: false, status: 'OPEN') }
    let!(:short_position) { create(:position, side: 'SHORT', entry_price: 50000, take_profit: 49000, stop_loss: 51000, day_trading: false, status: 'OPEN') }

    before do
      allow(manager).to receive(:get_current_price).and_return(51500) # Price above long TP, below short SL
    end

    it 'identifies take profit triggers for long positions' do
      result = manager.check_swing_tp_sl_triggers
      long_trigger = result.find { |t| t[:position] == long_position }
      
      expect(long_trigger).not_to be_nil
      expect(long_trigger[:trigger]).to eq('take_profit')
      expect(long_trigger[:current_price]).to eq(51500)
    end

    it 'identifies stop loss triggers for short positions' do
      result = manager.check_swing_tp_sl_triggers
      short_trigger = result.find { |t| t[:position] == short_position }
      
      expect(short_trigger).not_to be_nil
      expect(short_trigger[:trigger]).to eq('stop_loss')
      expect(short_trigger[:current_price]).to eq(51500)
    end
  end

  describe '#close_expiring_positions' do
    let!(:trading_pair) { create(:trading_pair, product_id: 'BTC-USD-PERP', expiry_date: 1.day.from_now) }
    let!(:expiring_position) { create(:position, product_id: 'BTC-USD-PERP', day_trading: false, status: 'OPEN') }

    before do
      allow(Rails.application.config).to receive(:swing_trading_config).and_return({expiry_buffer_days: 2})
      allow(manager).to receive(:get_current_price).and_return(50000)
      allow(positions_service).to receive(:close_position).and_return({'success' => true})
    end

    it 'closes positions approaching expiry' do
      expect(manager).to receive(:close_swing_position).with(expiring_position, 50000, 'Contract expiry approaching')
      
      result = manager.close_expiring_positions
      expect(result).to eq(1)
    end

    it 'handles positions without current price' do
      allow(manager).to receive(:get_current_price).and_return(nil)
      expect(logger).to receive(:warn).with("Could not get current price for BTC-USD-PERP, skipping closure")
      
      result = manager.close_expiring_positions
      expect(result).to eq(0)
    end
  end

  describe '#close_max_hold_positions' do
    let!(:old_position) { create(:position, day_trading: false, status: 'OPEN', entry_time: 6.days.ago) }

    before do
      allow(Rails.application.config).to receive(:swing_trading_config).and_return({max_hold_days: 5})
      allow(manager).to receive(:get_current_price).and_return(50000)
      allow(positions_service).to receive(:close_position).and_return({'success' => true})
    end

    it 'closes positions exceeding max hold period' do
      expect(manager).to receive(:close_swing_position).with(old_position, 50000, 'Maximum holding period exceeded')
      
      result = manager.close_max_hold_positions
      expect(result).to eq(1)
    end
  end

  describe '#close_tp_sl_positions' do
    let!(:triggered_position) { create(:position, side: 'LONG', entry_price: 50000, take_profit: 51000, day_trading: false, status: 'OPEN') }

    before do
      allow(manager).to receive(:get_current_price).and_return(51500)
      allow(positions_service).to receive(:close_position).and_return({'success' => true})
    end

    it 'closes positions that hit take profit' do
      expect(manager).to receive(:close_swing_position).with(triggered_position, 51500, 'Take profit triggered')
      
      result = manager.close_tp_sl_positions
      expect(result).to eq(1)
    end
  end

  describe '#get_swing_position_summary' do
    before do
      Position.delete_all
      allow(manager).to receive(:get_current_price).with('BTC-USD-PERP').and_return(51000)
      allow(manager).to receive(:get_current_price).with('ETH-USD-PERP').and_return(3100)
    end

    let!(:btc_position) { create(:position, product_id: 'BTC-USD-PERP', size: 5, entry_price: 50000, day_trading: false, status: 'OPEN') }
    let!(:eth_position) { create(:position, product_id: 'ETH-USD-PERP', size: 10, entry_price: 3000, day_trading: false, status: 'OPEN') }
    let!(:day_position) { create(:position, product_id: 'BTC-USD-PERP', day_trading: true, status: 'OPEN') }

    it 'returns comprehensive swing position summary' do
      result = manager.get_swing_position_summary
      
      expect(result[:total_positions]).to eq(2)
      expect(result[:total_exposure]).to be > 0
      expect(result[:unrealized_pnl]).to be > 0
      expect(result[:positions_by_asset]).to have_key('BTC')
      expect(result[:positions_by_asset]).to have_key('ETH')
      expect(result[:positions]).to have(2).items
      expect(result[:risk_metrics]).to be_present
    end

    it 'excludes day trading positions from summary' do
      result = manager.get_swing_position_summary
      position_ids = result[:positions].map { |p| p[:id] }
      
      expect(position_ids).to include(btc_position.id)
      expect(position_ids).to include(eth_position.id)
      expect(position_ids).not_to include(day_position.id)
    end
  end

  describe '#get_swing_balance_summary' do
    let(:balance_response) do
      {
        'futures_buying_power' => '50000.00',
        'total_usd_balance' => '100000.00',
        'cfm_usd_balance' => '75000.00',
        'unrealized_pnl' => '2500.00',
        'initial_margin' => '15000.00',
        'available_margin' => '35000.00',
        'liquidation_threshold' => '10000.00',
        'liquidation_buffer_amount' => '5000.00',
        'liquidation_buffer_percentage' => '0.33'
      }.to_json
    end

    let(:margin_response) do
      {
        'margin_window' => {'margin_window_type' => 'OVERNIGHT_MARGIN'},
        'is_intraday_margin_killswitch_enabled' => false
      }.to_json
    end

    before do
      balance_resp = double('response', body: balance_response)
      margin_resp = double('response', body: margin_response)
      
      allow(positions_service).to receive(:send).with(:authenticated_get, '/api/v3/brokerage/cfm/balance_summary', {}).and_return(balance_resp)
      allow(positions_service).to receive(:send).with(:authenticated_get, '/api/v3/brokerage/cfm/intraday_margin_setting', {}).and_return(margin_resp)
    end

    it 'returns balance summary with margin information' do
      result = manager.get_swing_balance_summary
      
      expect(result[:futures_buying_power]).to eq(50000.0)
      expect(result[:total_usd_balance]).to eq(100000.0)
      expect(result[:available_margin]).to eq(35000.0)
      expect(result[:overnight_margin_enabled]).to be true
    end

    it 'handles API errors gracefully' do
      allow(positions_service).to receive(:send).and_raise(StandardError.new('API Error'))
      
      result = manager.get_swing_balance_summary
      expect(result[:error]).to include('Failed to retrieve balance information')
    end
  end

  describe '#check_swing_risk_limits' do
    before do
      Position.delete_all
      allow(manager).to receive(:get_swing_balance_summary).and_return({
        total_usd_balance: 100000.0,
        available_margin: 30000.0
      })
      allow(manager).to receive(:get_current_price).and_return(50000)
      allow(Rails.application.config).to receive(:swing_trading_config).and_return({
        max_overnight_exposure: 0.3,
        margin_safety_buffer: 0.2,
        max_leverage_overnight: 3
      })
    end

    let!(:swing_position) { create(:position, product_id: 'BTC-USD-PERP', size: 10, entry_price: 50000, day_trading: false, status: 'OPEN') }

    it 'identifies risk limit violations' do
      # Position exposure: 10 * 50000 = 500000, which is 5x the account balance
      result = manager.check_swing_risk_limits
      
      expect(result[:violations]).not_to be_empty
      expect(result[:risk_status]).to eq('violations_detected')
    end

    it 'returns acceptable status when within limits' do
      swing_position.update!(size: 1) # Reduce position size to be within limits
      
      result = manager.check_swing_risk_limits
      expect(result[:risk_status]).to eq('acceptable')
    end
  end

  describe '#force_close_all_swing_positions' do
    before do
      # Clear any existing positions
      Position.delete_all
      allow(manager).to receive(:get_current_price).and_return(50000)
      allow(positions_service).to receive(:close_position).and_return({'success' => true})
    end

    context 'with swing and day trading positions' do
      let!(:swing_position1) { create(:position, day_trading: false, status: 'OPEN') }
      let!(:swing_position2) { create(:position, day_trading: false, status: 'OPEN') }
      let!(:day_position) { create(:position, day_trading: true, status: 'OPEN') }

      it 'force closes all swing positions' do
        expect(manager).to receive(:close_swing_position).twice
        expect(logger).to receive(:warn).with('Force closing all 2 swing positions: Emergency closure')
        expect(logger).to receive(:warn).with('Force closed 2 swing positions')
        
        result = manager.force_close_all_swing_positions('Emergency closure')
        expect(result).to eq(2)
      end

      it 'excludes day trading positions' do
        expect(manager).to receive(:close_swing_position).twice # Only swing positions
        
        manager.force_close_all_swing_positions
      end
    end

    context 'without current price' do
      let!(:swing_position1) { create(:position, day_trading: false, status: 'OPEN') }
      let!(:swing_position2) { create(:position, day_trading: false, status: 'OPEN') }

      it 'handles positions without current price by using entry price' do
        allow(manager).to receive(:get_current_price).and_return(nil)
        expect(swing_position1).to receive(:force_close!)
        expect(swing_position2).to receive(:force_close!)
        
        result = manager.force_close_all_swing_positions
        expect(result).to eq(2)
      end
    end
  end

  describe 'private methods' do
    describe '#get_current_price' do
      it 'falls back to API when no recent candle data' do
        api_response = {
          'pricebook' => {
            'bids' => [{'price' => '50900'}],
            'asks' => [{'price' => '51100'}]
          }
        }.to_json
        
        resp = double('response', body: api_response)
        allow(positions_service).to receive(:send).with(:authenticated_get, '/api/v3/brokerage/market/product_book', {product_id: 'BTC-USD-PERP', limit: 1}).and_return(resp)
        
        price = manager.send(:get_current_price, 'BTC-USD-PERP')
        expect(price).to eq(51000.0) # (50900 + 51100) / 2
      end

      it 'returns nil when API call fails' do
        allow(positions_service).to receive(:send).and_raise(StandardError.new('API Error'))
        expect(logger).to receive(:error).with('Failed to get current price for BTC-USD-PERP: API Error')
        
        price = manager.send(:get_current_price, 'BTC-USD-PERP')
        expect(price).to be_nil
      end
    end

    describe '#close_swing_position' do
      let(:position) { create(:position, product_id: 'BTC-USD-PERP', size: 5, day_trading: false, status: 'OPEN') }

      it 'closes position via API and updates local record' do
        allow(positions_service).to receive(:close_position).with(product_id: 'BTC-USD-PERP', size: 5).and_return({'success' => true})
        expect(position).to receive(:close_position!).with(50000)
        
        manager.send(:close_swing_position, position, 50000, 'Test closure')
      end

      it 'raises error when API closure fails' do
        allow(positions_service).to receive(:close_position).and_return({'error' => 'Insufficient funds'})
        
        expect {
          manager.send(:close_swing_position, position, 50000, 'Test closure')
        }.to raise_error('API closure failed: Insufficient funds')
      end
    end
  end
end