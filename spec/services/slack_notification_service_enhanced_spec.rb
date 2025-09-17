# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SlackNotificationService do
  let(:mock_client) { instance_double(Slack::Web::Client) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_ENABLED').and_return('true')
    allow(ENV).to receive(:[]).with('SLACK_BOT_TOKEN').and_return('test-token')
    allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
    allow(mock_client).to receive(:chat_postMessage).and_return(true)

    # Mock monitoring config
    allow(Rails.application.config).to receive(:monitoring_config).and_return({
      enable_position_type_alerts: true,
      slack_notifications: {
        day_trading_channel: '#day-trading-test',
        swing_trading_channel: '#swing-trading-test',
        risk_alerts_channel: '#risk-alerts-test',
        margin_alerts_channel: '#margin-alerts-test'
      }
    })
  end

  describe '.position_type_alert' do
    context 'when alerts are enabled' do
      it 'sends day trading alerts to correct channel' do
        expect(mock_client).to receive(:chat_postMessage).with(
          hash_including(channel: '#day-trading-test')
        )

        described_class.position_type_alert(
          'day_trading',
          'closure',
          'Test day trading alert',
          'Test details'
        )
      end

      it 'sends swing trading alerts to correct channel' do
        expect(mock_client).to receive(:chat_postMessage).with(
          hash_including(channel: '#swing-trading-test')
        )

        described_class.position_type_alert(
          'swing_trading',
          'warning',
          'Test swing trading alert'
        )
      end

      it 'formats closure alerts correctly' do
        expect(mock_client).to receive(:chat_postMessage) do |args|
          expect(args[:text]).to include('🔴')
          expect(args[:text]).to include('Day Trading Alert')
          expect(args[:attachments].first[:color]).to eq('danger')
        end

        described_class.position_type_alert(
          'day_trading',
          'closure',
          'Position closure required'
        )
      end

      it 'formats warning alerts correctly' do
        expect(mock_client).to receive(:chat_postMessage) do |args|
          expect(args[:text]).to include('⚠️')
          expect(args[:attachments].first[:color]).to eq('warning')
        end

        described_class.position_type_alert(
          'swing_trading',
          'warning',
          'Position warning'
        )
      end

      it 'includes details when provided' do
        expect(mock_client).to receive(:chat_postMessage) do |args|
          fields = args[:attachments].first[:fields]
          details_field = fields.find { |f| f[:title] == 'Details' }
          expect(details_field[:value]).to eq('Test details')
        end

        described_class.position_type_alert(
          'day_trading',
          'info',
          'Test alert',
          'Test details'
        )
      end
    end

    context 'when alerts are disabled' do
      before do
        allow(Rails.application.config).to receive(:monitoring_config).and_return({
          enable_position_type_alerts: false
        })
      end

      it 'does not send alerts when disabled' do
        expect(mock_client).not_to receive(:chat_postMessage)

        described_class.position_type_alert(
          'day_trading',
          'closure',
          'Test alert'
        )
      end
    end
  end

  describe '.portfolio_exposure_alert' do
    let(:exposure_data) do
      {
        day_trading_exposure: 45.5,
        swing_trading_exposure: 25.0,
        total_exposure: 70.5,
        warnings: ['Day trading exposure exceeds limit']
      }
    end

    it 'sends exposure alerts to risk channel' do
      expect(mock_client).to receive(:chat_postMessage).with(
        hash_including(channel: '#risk-alerts-test')
      )

      described_class.portfolio_exposure_alert(exposure_data)
    end

    it 'formats exposure data correctly' do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:text]).to include('⚠️')
        expect(args[:text]).to include('Portfolio Exposure Report')
        
        fields = args[:attachments].first[:fields]
        day_field = fields.find { |f| f[:title] == 'Day Trading Exposure' }
        swing_field = fields.find { |f| f[:title] == 'Swing Trading Exposure' }
        total_field = fields.find { |f| f[:title] == 'Total Exposure' }
        warnings_field = fields.find { |f| f[:title] == 'Warnings' }

        expect(day_field[:value]).to eq('45.5%')
        expect(swing_field[:value]).to eq('25.0%')
        expect(total_field[:value]).to eq('70.5%')
        expect(warnings_field[:value]).to include('Day trading exposure exceeds limit')
      end

      described_class.portfolio_exposure_alert(exposure_data)
    end

    it 'uses warning color when warnings present' do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:attachments].first[:color]).to eq('warning')
      end

      described_class.portfolio_exposure_alert(exposure_data)
    end

    it 'uses good color when no warnings' do
      exposure_data[:warnings] = []

      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:attachments].first[:color]).to eq('good')
      end

      described_class.portfolio_exposure_alert(exposure_data)
    end
  end

  describe '.margin_window_transition' do
    let(:window_data) do
      {
        current_window: 'INTRADAY_MARGIN',
        window_end_time: '2025-01-15T21:00:00Z',
        next_transition: 'Switches to overnight margin at 21:00 UTC'
      }
    end

    it 'sends margin alerts to margin channel' do
      expect(mock_client).to receive(:chat_postMessage).with(
        hash_including(channel: '#margin-alerts-test')
      )

      described_class.margin_window_transition(window_data)
    end

    it 'formats intraday margin correctly' do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:text]).to include('🟢')
        expect(args[:text]).to include('INTRADAY_MARGIN')
        expect(args[:attachments].first[:color]).to eq('good')
        
        fields = args[:attachments].first[:fields]
        window_field = fields.find { |f| f[:title] == 'Current Window' }
        expect(window_field[:value]).to eq('Intraday margin')
      end

      described_class.margin_window_transition(window_data)
    end

    it 'formats overnight margin correctly' do
      window_data[:current_window] = 'OVERNIGHT_MARGIN'

      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:text]).to include('🟡')
        expect(args[:attachments].first[:color]).to eq('warning')
      end

      described_class.margin_window_transition(window_data)
    end

    it 'includes transition information' do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        fields = args[:attachments].first[:fields]
        transition_field = fields.find { |f| f[:title] == 'Next Transition' }
        expect(transition_field[:value]).to include('overnight margin at 21:00 UTC')
      end

      described_class.margin_window_transition(window_data)
    end
  end

  describe 'channel routing' do
    it 'routes day trading alerts to day trading channel' do
      expect(described_class.send(:day_trading_channel)).to eq('#day-trading-test')
    end

    it 'routes swing trading alerts to swing trading channel' do
      expect(described_class.send(:swing_trading_channel)).to eq('#swing-trading-test')
    end

    it 'routes risk alerts to risk alerts channel' do
      expect(described_class.send(:risk_alerts_channel)).to eq('#risk-alerts-test')
    end

    it 'routes margin alerts to margin alerts channel' do
      expect(described_class.send(:margin_alerts_channel)).to eq('#margin-alerts-test')
    end

    it 'falls back to default channels when not configured' do
      allow(Rails.application.config).to receive(:monitoring_config).and_return({
        slack_notifications: {}
      })

      expect(described_class.send(:day_trading_channel)).to eq('#day-trading')
      expect(described_class.send(:swing_trading_channel)).to eq('#swing-trading')
      expect(described_class.send(:risk_alerts_channel)).to eq('#risk-alerts')
      expect(described_class.send(:margin_alerts_channel)).to eq('#margin-alerts')
    end
  end

  describe 'message formatting edge cases' do
    it 'handles empty position type gracefully' do
      result = described_class.send(:format_position_type_alert, '', 'warning', 'test')
      expect(result).to eq({})
    end

    it 'handles missing exposure data gracefully' do
      result = described_class.send(:format_portfolio_exposure_message, nil)
      expect(result).to eq({})
    end

    it 'handles missing window data gracefully' do
      result = described_class.send(:format_margin_window_message, {})
      expect(result[:text]).to include('Unknown')
    end

    it 'handles unknown alert types' do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:text]).to include('📢')
        expect(args[:attachments].first[:color]).to eq('good')
      end

      described_class.position_type_alert(
        'day_trading',
        'unknown_type',
        'Test alert'
      )
    end
  end
end