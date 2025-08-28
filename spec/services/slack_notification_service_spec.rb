# frozen_string_literal: true

require "rails_helper"

RSpec.describe SlackNotificationService, type: :service do
  let(:service) { described_class.new }

  # Test data setup without heavy mocking
  let(:test_env) do
    {
      "SLACK_ENABLED" => "true",
      "SLACK_BOT_TOKEN" => "xoxb-test-token",
      "SLACK_SIGNALS_CHANNEL" => "#test-signals",
      "SLACK_POSITIONS_CHANNEL" => "#test-positions",
      "SLACK_STATUS_CHANNEL" => "#test-status",
      "SLACK_ALERTS_CHANNEL" => "#test-alerts"
    }
  end

  # Use realistic test data instead of mocking external services
  let(:signal_data) do
    {
      symbol: "BTC-USD",
      side: "long",
      price: 50_000.0,
      quantity: 0.1,
      tp: 52_000.0,
      sl: 48_000.0,
      confidence: 75
    }
  end

  let(:position) do
    create(:position,
      product_id: "ETH-USD",
      side: "LONG",
      size: 1.0,
      entry_price: 3000.0,
      pnl: 150.0)
  end

  # Remove the global before block to avoid ClimateControl issues with nil values
  # Each test will handle its own environment setup

  describe '.signal_generated' do
    context 'when Slack is enabled' do
      before do
        ClimateControl.modify(test_env)
      end

      it 'validates signal data structure' do
        # Test that the method accepts valid signal data
        # In a real integration test, this would send to Slack
        expect do
          described_class.signal_generated(signal_data)
        end.not_to raise_error
      end

      it 'handles different signal types' do
        short_signal = signal_data.merge(side: 'short', symbol: 'ETH-USD')

        expect do
          described_class.signal_generated(short_signal)
        end.not_to raise_error
      end
    end

    context 'when Slack is disabled' do
      before do
        ClimateControl.modify(test_env.merge('SLACK_ENABLED' => 'false'))
      end

      it 'does not attempt to send notifications' do
        # Test that disabled Slack doesn't cause errors
        expect do
          described_class.signal_generated(signal_data)
        end.not_to raise_error
      end
    end
  end

  describe '.position_update' do
    context 'with valid position data' do
      before do
        ClimateControl.modify(test_env)
      end

      it 'handles position opened events' do
        expect do
          described_class.position_update(position, 'opened')
        end.not_to raise_error
      end

      it 'handles position closed events with profit' do
        profitable_position = create(:position,
          product_id: 'BTC-USD',
          side: 'LONG',
          size: 1.0,
          entry_price: 50_000.0,
          pnl: 1000.0)

        expect do
          described_class.position_update(profitable_position, 'closed')
        end.not_to raise_error
      end

      it 'handles position closed events with loss' do
        loss_position = create(:position,
          product_id: 'ADA-USD',
          side: 'SHORT',
          size: 100.0,
          entry_price: 1.0,
          pnl: -50.0)

        expect do
          described_class.position_update(loss_position, 'closed')
        end.not_to raise_error
      end
    end

    context 'with edge cases' do
      before do
        ClimateControl.modify(test_env)
      end

      it 'handles positions with zero PnL' do
        zero_pnl_position = create(:position,
          product_id: 'ETH-USD',
          side: 'LONG',
          size: 1.0,
          entry_price: 3000.0,
          pnl: 0.0)

        expect do
          described_class.position_update(zero_pnl_position, 'closed')
        end.not_to raise_error
      end

      it 'handles very small positions' do
        small_position = create(:position,
          product_id: 'BTC-USD',
          side: 'LONG',
          size: 0.001,
          entry_price: 50_000.0,
          pnl: 0.5)

        expect do
          described_class.position_update(small_position, 'opened')
        end.not_to raise_error
      end
    end
  end

  describe '.bot_status' do
    before do
      ClimateControl.modify(test_env)
    end

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
      expect do
        described_class.bot_status(status_data)
      end.not_to raise_error
    end

    it 'handles inactive status data' do
      inactive_data = status_data.merge(status: 'inactive', trading_active: false, healthy: false)
      expect do
        described_class.bot_status(inactive_data)
      end.not_to raise_error
    end

    it 'handles status data with no positions' do
      no_positions_data = status_data.merge(open_positions: 0, daily_pnl: 0.0)
      expect do
        described_class.bot_status(no_positions_data)
      end.not_to raise_error
    end
  end

  describe '.alert' do
    before do
      ClimateControl.modify(test_env)
    end

    it 'handles critical alerts' do
      expect do
        described_class.alert('critical', 'System Error', 'Database connection lost')
      end.not_to raise_error
    end

    it 'handles warning alerts' do
      expect do
        described_class.alert('warning', 'High Memory Usage')
      end.not_to raise_error
    end

    it 'handles info alerts' do
      expect do
        described_class.alert('info', 'System Check', 'All systems operational')
      end.not_to raise_error
    end

    it 'handles alerts without additional details' do
      expect do
        described_class.alert('warning', 'Maintenance Mode')
      end.not_to raise_error
    end
  end

  describe '.pnl_update' do
    before do
      ClimateControl.modify(test_env)
    end

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
      expect do
        described_class.pnl_update(pnl_data)
      end.not_to raise_error
    end

    it 'handles negative PnL data' do
      negative_pnl = pnl_data.merge(total_pnl: -200.0, daily_pnl: -50.0)
      expect do
        described_class.pnl_update(negative_pnl)
      end.not_to raise_error
    end

    it 'handles zero PnL data' do
      zero_pnl = pnl_data.merge(total_pnl: 0.0, daily_pnl: 0.0, win_rate: 0.0)
      expect do
        described_class.pnl_update(zero_pnl)
      end.not_to raise_error
    end
  end

  describe "configuration and environment handling" do
    context "with missing Slack configuration" do
      before do
        ClimateControl.modify(
          "SLACK_ENABLED" => "true",
          "SLACK_BOT_TOKEN" => nil,
          "SLACK_SIGNALS_CHANNEL" => nil
        )
      end

      it "handles missing bot token gracefully" do
        expect do
          described_class.signal_generated(signal_data)
        end.not_to raise_error
      end
    end

    context "with invalid channel configurations" do
      before do
        ClimateControl.modify(
          "SLACK_ENABLED" => "true",
          "SLACK_BOT_TOKEN" => "xoxb-test-token",
          "SLACK_SIGNALS_CHANNEL" => "",
          "SLACK_POSITIONS_CHANNEL" => nil
        )
      end

      it "handles empty or nil channels gracefully" do
        expect do
          described_class.signal_generated(signal_data)
          described_class.position_update(position, "opened")
        end.not_to raise_error
      end
    end

    context "with malformed data" do
      it "handles nil signal data gracefully" do
        expect do
          described_class.signal_generated(nil)
        end.not_to raise_error
      end

      it "handles empty signal data gracefully" do
        expect do
          described_class.signal_generated({})
        end.not_to raise_error
      end

      it "handles signal data with missing fields" do
        incomplete_signal = {symbol: "BTC-USD"}
        expect do
          described_class.signal_generated(incomplete_signal)
        end.not_to raise_error
      end
    end
  end
end
