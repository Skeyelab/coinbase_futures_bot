# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SlackNotificationService, type: :service do
  let(:service) { described_class.new }

  # Mock Slack client to prevent real API calls during tests
  def mock_slack_client
    mock_client = instance_double(Slack::Web::Client)
    allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
    allow(mock_client).to receive(:chat_postMessage).and_return(true)

    # Reset the cached client instance in the service
    described_class.instance_variable_set(:@client, nil)

    mock_client
  end

  # Test data setup without heavy mocking - avoid nil values for ClimateControl
  let(:test_env) do
    {
      'SLACK_ENABLED' => 'true',
      'SLACK_BOT_TOKEN' => 'xoxb-test-token',
      'SLACK_SIGNALS_CHANNEL' => '#test-signals',
      'SLACK_POSITIONS_CHANNEL' => '#test-positions',
      'SLACK_STATUS_CHANNEL' => '#test-status',
      'SLACK_ALERTS_CHANNEL' => '#test-alerts',
      'SLACK_WEBHOOK_URL' => 'https://hooks.slack.com/test'
    }
  end

  let(:disabled_env) do
    {
      'SLACK_ENABLED' => 'false',
      'SLACK_BOT_TOKEN' => 'xoxb-test-token',
      'SLACK_SIGNALS_CHANNEL' => '#test-signals',
      'SLACK_POSITIONS_CHANNEL' => '#test-positions',
      'SLACK_STATUS_CHANNEL' => '#test-status',
      'SLACK_ALERTS_CHANNEL' => '#test-alerts',
      'SLACK_WEBHOOK_URL' => 'https://hooks.slack.com/test'
    }
  end

  let(:missing_config_env) do
    {
      'SLACK_ENABLED' => 'true',
      'SLACK_BOT_TOKEN' => '',
      'SLACK_SIGNALS_CHANNEL' => '',
      'SLACK_POSITIONS_CHANNEL' => '#test-positions',
      'SLACK_STATUS_CHANNEL' => '#test-status',
      'SLACK_ALERTS_CHANNEL' => '#test-alerts',
      'SLACK_WEBHOOK_URL' => 'https://hooks.slack.com/test'
    }
  end

  let(:invalid_channels_env) do
    {
      'SLACK_ENABLED' => 'true',
      'SLACK_BOT_TOKEN' => 'xoxb-test-token',
      'SLACK_SIGNALS_CHANNEL' => '',
      'SLACK_POSITIONS_CHANNEL' => '',
      'SLACK_STATUS_CHANNEL' => '#test-status',
      'SLACK_ALERTS_CHANNEL' => '#test-alerts',
      'SLACK_WEBHOOK_URL' => 'https://hooks.slack.com/test'
    }
  end

  # Use realistic test data instead of mocking external services
  let(:signal_data) do
    {
      symbol: 'BTC-USD',
      side: 'long',
      price: 50_000.0,
      quantity: 0.1,
      tp: 52_000.0,
      sl: 48_000.0,
      confidence: 75
    }
  end

  let(:position) do
    create(:position,
           product_id: 'ETH-USD',
           side: 'LONG',
           size: 1.0,
           entry_price: 3000.0,
           pnl: 150.0)
  end

  # Remove the global before block to avoid ClimateControl issues with nil values
  # Each test will handle its own environment setup

  describe '.signal_generated' do
    it 'handles valid signal data gracefully' do
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.signal_generated(signal_data)
      end
    end

    it 'handles different signal types' do
      short_signal = signal_data.merge(side: 'short', symbol: 'ETH-USD')

      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.signal_generated(short_signal)
      end
    end
  end

  describe '.position_update' do
    it 'handles position opened events' do
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.position_update(position, 'opened')
      end
    end

    it 'handles position closed events with profit' do
      profitable_position = create(:position,
                                   product_id: 'BTC-USD',
                                   side: 'LONG',
                                   size: 1.0,
                                   entry_price: 50_000.0,
                                   pnl: 1000.0)

      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.position_update(profitable_position, 'closed')
      end
    end

    it 'handles position closed events with loss' do
      loss_position = create(:position,
                             product_id: 'ADA-USD',
                             side: 'SHORT',
                             size: 100.0,
                             entry_price: 1.0,
                             pnl: -50.0)

      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.position_update(loss_position, 'closed')
      end
    end

    it 'handles positions with zero PnL' do
      zero_pnl_position = create(:position,
                                 product_id: 'ETH-USD',
                                 side: 'LONG',
                                 size: 1.0,
                                 entry_price: 3000.0,
                                 pnl: 0.0)

      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.position_update(zero_pnl_position, 'closed')
      end
    end

    it 'handles very small positions' do
      small_position = create(:position,
                              product_id: 'BTC-USD',
                              side: 'LONG',
                              size: 0.001,
                              entry_price: 50_000.0,
                              pnl: 0.5)

      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.position_update(small_position, 'opened')
      end
    end
  end

  describe '.bot_status' do
    let(:status_data) do
      {
        status: 'active',
        trading_active: true,
        open_positions: 5,
        daily_pnl: 250.0,
        last_signal_time: '10:30 UTC',
        healthy: true
      }
    end

    it 'handles active status data' do
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.bot_status(status_data)
      end
    end

    it 'handles inactive status data' do
      inactive_data = status_data.merge(status: 'inactive', trading_active: false, healthy: false)
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.bot_status(inactive_data)
      end
    end

    it 'handles status data with no positions' do
      no_positions_data = status_data.merge(open_positions: 0, daily_pnl: 0.0)
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.bot_status(no_positions_data)
      end
    end
  end

  describe '.alert' do
    it 'handles critical alerts' do
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.alert('critical', 'System Error', 'Database connection lost')
      end
    end

    it 'handles warning alerts' do
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.alert('warning', 'High Memory Usage')
      end
    end

    it 'handles info alerts' do
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.alert('info', 'System Check', 'All systems operational')
      end
    end

    it 'handles alerts without additional details' do
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.alert('warning', 'Maintenance Mode')
      end
    end
  end

  describe '.pnl_update' do
    let(:pnl_data) do
      {
        total_pnl: 500.0,
        daily_pnl: 100.0,
        open_positions: 3,
        closed_today: 2,
        win_rate: 66.7
      }
    end

    it 'handles positive PnL data' do
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.pnl_update(pnl_data)
      end
    end

    it 'handles negative PnL data' do
      negative_pnl = pnl_data.merge(total_pnl: -200.0, daily_pnl: -50.0)
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.pnl_update(negative_pnl)
      end
    end

    it 'handles zero PnL data' do
      zero_pnl = pnl_data.merge(total_pnl: 0.0, daily_pnl: 0.0, win_rate: 0.0)
      ClimateControl.modify(test_env) do
        mock_client = mock_slack_client
        expect(mock_client).to receive(:chat_postMessage).once
        described_class.pnl_update(zero_pnl)
      end
    end
  end

  describe 'configuration and environment handling' do
    context 'with missing Slack configuration' do
      it 'handles missing bot token gracefully' do
        # Test with Slack disabled
        ClimateControl.modify(disabled_env) do
          expect do
            described_class.signal_generated({ symbol: 'BTC-USD', side: 'long', price: 50_000.0 })
          end.not_to raise_error
        end
      end
    end

    context 'with invalid channel configurations' do
      it 'handles empty channels gracefully' do
        # Test with missing channel configuration
        ClimateControl.modify(missing_config_env) do
          expect do
            described_class.signal_generated({ symbol: 'BTC-USD', side: 'long', price: 50_000.0 })
          end.not_to raise_error
        end
      end
    end

    context 'with malformed data' do
      it 'handles nil signal data gracefully' do
        ClimateControl.modify(test_env) do
          mock_client = mock_slack_client
          # Should not call Slack client for nil data
          expect(mock_client).not_to receive(:chat_postMessage)
          expect do
            described_class.signal_generated(nil)
          end.not_to raise_error
        end
      end

      it 'handles empty signal data gracefully' do
        ClimateControl.modify(test_env) do
          mock_client = mock_slack_client
          # Should not call Slack client for empty data
          expect(mock_client).not_to receive(:chat_postMessage)
          expect do
            described_class.signal_generated({})
          end.not_to raise_error
        end
      end

      it 'handles signal data with missing fields' do
        incomplete_signal = { symbol: 'BTC-USD' }
        ClimateControl.modify(test_env) do
          mock_client = mock_slack_client
          expect(mock_client).to receive(:chat_postMessage).once
          expect do
            described_class.signal_generated(incomplete_signal)
          end.not_to raise_error
        end
      end
    end
  end
end
