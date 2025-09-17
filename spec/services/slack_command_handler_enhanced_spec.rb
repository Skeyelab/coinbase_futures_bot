# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SlackCommandHandler do
  let(:authorized_user_id) { 'U12345' }
  let(:unauthorized_user_id) { 'U99999' }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_AUTHORIZED_USERS').and_return(authorized_user_id)
  end

  describe '.handle_command' do
    context 'with enhanced status command' do
      let!(:day_position) { create(:position, day_trading: true, status: 'OPEN') }
      let!(:swing_position) { create(:position, day_trading: false, status: 'OPEN') }
      let(:params) { { command: '/bot-status', user_id: authorized_user_id } }

      before do
        allow(Rails.cache).to receive(:fetch).with('trading_active', expires_in: 1.hour).and_return(true)
        allow(GoodJob::Job).to receive(:where).and_return(double(order: double(first: nil)))
      end

      it 'includes position type breakdown' do
        response = described_class.handle_command(params)

        expect(response[:attachments].first[:fields]).to include(
          hash_including(title: 'Day Trading Positions', value: '1'),
          hash_including(title: 'Swing Trading Positions', value: '1'),
          hash_including(title: 'Total Positions', value: '2')
        )
      end
    end

    context 'with detailed status command' do
      let(:params) { { command: '/bot-detailed-status', user_id: authorized_user_id } }
      let(:mock_client) { instance_double(Coinbase::Client) }
      let(:balance_summary) do
        {
          'balance_summary' => {
            'available_margin' => { 'value' => '5000.00' },
            'initial_margin' => { 'value' => '10000.00' },
            'liquidation_buffer_percentage' => '20.5',
            'unrealized_pnl' => { 'value' => '250.00' },
            'daily_realized_pnl' => { 'value' => '100.00' }
          }
        }
      end
      let(:margin_window) do
        {
          'margin_window' => {
            'margin_window_type' => 'INTRADAY_MARGIN'
          }
        }
      end

      before do
        allow(Coinbase::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:futures_balance_summary).and_return(balance_summary)
        allow(mock_client).to receive(:margin_window).and_return(margin_window)
        create(:position, day_trading: true, status: 'OPEN')
        create(:position, day_trading: false, status: 'OPEN')
      end

      it 'returns detailed status with margin information' do
        response = described_class.handle_command(params)

        expect(response[:text]).to eq('📊 Detailed Bot Status')
        expect(response[:attachments].first[:fields]).to include(
          hash_including(title: 'Margin Window', value: 'INTRADAY_MARGIN'),
          hash_including(title: 'Available Margin', value: '$5000.00'),
          hash_including(title: 'Liquidation Buffer', value: '20.5%'),
          hash_including(title: 'Unrealized PnL', value: '$250.00')
        )
      end

      it 'handles API errors gracefully' do
        allow(mock_client).to receive(:futures_balance_summary).and_raise(StandardError.new("API Error"))

        response = described_class.handle_command(params)

        expect(response[:attachments].first[:color]).to eq('danger')
        expect(response[:attachments].first[:fields]).to include(
          hash_including(title: 'Margin Window', value: 'Error')
        )
      end
    end

    context 'with enhanced positions command' do
      let!(:day_position) { create(:position, day_trading: true, status: 'OPEN', product_id: 'BTC-USD') }
      let!(:swing_position) { create(:position, day_trading: false, status: 'OPEN', product_id: 'ETH-USD') }

      it 'filters by day trading positions' do
        params = { command: '/bot-positions', text: 'day', user_id: authorized_user_id }
        
        response = described_class.handle_command(params)

        expect(response[:attachments].length).to eq(1)
        expect(response[:attachments].first[:fields]).to include(
          hash_including(title: 'Symbol', value: 'BTC-USD')
        )
      end

      it 'filters by swing trading positions' do
        params = { command: '/bot-positions', text: 'swing', user_id: authorized_user_id }
        
        response = described_class.handle_command(params)

        expect(response[:attachments].length).to eq(1)
        expect(response[:attachments].first[:fields]).to include(
          hash_including(title: 'Symbol', value: 'ETH-USD')
        )
      end

      it 'supports day-trading filter variant' do
        params = { command: '/bot-positions', text: 'day-trading', user_id: authorized_user_id }
        
        response = described_class.handle_command(params)

        expect(response[:attachments].length).to eq(1)
      end

      it 'supports swing_trading filter variant' do
        params = { command: '/bot-positions', text: 'swing_trading', user_id: authorized_user_id }
        
        response = described_class.handle_command(params)

        expect(response[:attachments].length).to eq(1)
      end
    end

    context 'with updated help command' do
      let(:params) { { command: '/bot-help', user_id: authorized_user_id } }

      it 'includes detailed status command in help' do
        response = described_class.handle_command(params)

        help_fields = response[:attachments].first[:fields]
        detailed_status_field = help_fields.find { |f| f[:title] == '/bot-detailed-status' }
        
        expect(detailed_status_field).to be_present
        expect(detailed_status_field[:value]).to include('margin and balance information')
      end

      it 'updates positions command help with new filters' do
        response = described_class.handle_command(params)

        help_fields = response[:attachments].first[:fields]
        positions_field = help_fields.find { |f| f[:title] == '/bot-positions [filter]' }
        
        expect(positions_field).to be_present
        expect(positions_field[:value]).to include('day', 'swing')
      end
    end
  end

  describe '.get_bot_status' do
    let!(:day_position) { create(:position, day_trading: true, status: 'OPEN') }
    let!(:swing_position) { create(:position, day_trading: false, status: 'OPEN') }

    before do
      allow(Rails.cache).to receive(:fetch).with('trading_active', expires_in: 1.hour).and_return(true)
      allow(GoodJob::Job).to receive(:where).and_return(double(order: double(first: nil)))
    end

    it 'includes position type breakdown' do
      status = described_class.send(:get_bot_status)

      expect(status).to include(
        day_trading_positions: 1,
        swing_trading_positions: 1,
        total_positions: 2,
        open_positions: 2  # backward compatibility
      )
    end

    it 'handles database errors gracefully' do
      allow(Position).to receive(:open).and_raise(StandardError.new("DB Error"))

      status = described_class.send(:get_bot_status)

      expect(status).to include(
        day_trading_positions: 0,
        swing_trading_positions: 0,
        total_positions: 0,
        healthy: false
      )
    end
  end

  describe '.get_detailed_status' do
    let(:mock_client) { instance_double(Coinbase::Client) }
    let(:balance_summary) do
      {
        'balance_summary' => {
          'available_margin' => { 'value' => '5000.00' },
          'initial_margin' => { 'value' => '10000.00' },
          'liquidation_buffer_percentage' => '15.0',
          'unrealized_pnl' => { 'value' => '100.00' },
          'daily_realized_pnl' => { 'value' => '50.00' }
        }
      }
    end
    let(:margin_window) do
      {
        'margin_window' => {
          'margin_window_type' => 'OVERNIGHT_MARGIN'
        }
      }
    end

    before do
      allow(Coinbase::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:futures_balance_summary).and_return(balance_summary)
      allow(mock_client).to receive(:margin_window).and_return(margin_window)
      create(:position, day_trading: true, status: 'OPEN')
    end

    it 'returns comprehensive status data' do
      status = described_class.send(:get_detailed_status)

      expect(status).to include(
        positions: hash_including(
          day_trading: 1,
          swing_trading: 0,
          total: 1
        ),
        margin: hash_including(
          current_window: 'OVERNIGHT_MARGIN',
          available_margin: '5000.00',
          total_margin: '10000.00',
          liquidation_buffer: '15.0'
        ),
        pnl: hash_including(
          unrealized: '100.00',
          daily_realized: '50.00'
        ),
        healthy: true
      )
    end

    it 'handles API failures gracefully' do
      allow(mock_client).to receive(:futures_balance_summary).and_raise(StandardError.new("API Error"))

      status = described_class.send(:get_detailed_status)

      expect(status).to include(
        healthy: false,
        error: "API Error"
      )
      expect(status[:margin][:current_window]).to eq("Error")
    end
  end

  describe '.get_positions with enhanced filtering' do
    let!(:day_position) { create(:position, day_trading: true, status: 'OPEN', product_id: 'BTC-USD') }
    let!(:swing_position) { create(:position, day_trading: false, status: 'OPEN', product_id: 'ETH-USD') }
    let!(:closed_position) { create(:position, day_trading: true, status: 'CLOSED', product_id: 'BTC-USD') }

    it 'filters day trading positions' do
      positions = described_class.send(:get_positions, 'day')
      expect(positions.length).to eq(1)
      expect(positions.first.day_trading).to be true
    end

    it 'filters swing trading positions' do
      positions = described_class.send(:get_positions, 'swing')
      expect(positions.length).to eq(1)
      expect(positions.first.day_trading).to be false
    end

    it 'supports underscore variants' do
      day_positions = described_class.send(:get_positions, 'day_trading')
      swing_positions = described_class.send(:get_positions, 'swing_trading')

      expect(day_positions.length).to eq(1)
      expect(swing_positions.length).to eq(1)
    end

    it 'supports hyphen variants' do
      day_positions = described_class.send(:get_positions, 'day-trading')
      swing_positions = described_class.send(:get_positions, 'swing-trading')

      expect(day_positions.length).to eq(1)
      expect(swing_positions.length).to eq(1)
    end

    it 'defaults to open positions when no filter provided' do
      positions = described_class.send(:get_positions, '')
      expect(positions.length).to eq(2)  # Only open positions
      expect(positions.all? { |p| p.status == 'OPEN' }).to be true
    end
  end
end