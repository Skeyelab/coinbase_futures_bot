# frozen_string_literal: true

require "rails_helper"

RSpec.describe SlackCommandHandler, type: :service do
  let(:authorized_user_id) { "U1234567890" }
  let(:unauthorized_user_id) { "U0987654321" }

  before do
    stub_const("ENV", ENV.to_hash.merge({
      "SLACK_AUTHORIZED_USERS" => authorized_user_id
    }))
  end

  describe ".handle_command" do
    context "with unauthorized user" do
      let(:params) do
        {
          user_id: unauthorized_user_id,
          command: "/bot-status",
          text: ""
        }
      end

      it "returns unauthorized response" do
        response = described_class.handle_command(params)

        expect(response[:text]).to include("not authorized")
        expect(response[:response_type]).to eq("ephemeral")
      end
    end

    context "with authorized user" do
      let(:base_params) do
        {
          user_id: authorized_user_id,
          token: "test-token",
          team_id: "T1234567890",
          channel_id: "C1234567890",
          user_name: "testuser"
        }
      end

      describe "/bot-status command" do
        let(:params) { base_params.merge(command: "/bot-status", text: "") }

        before do
          # Mock the Position class methods that get_bot_status calls
          allow(Position).to receive_message_chain(:open, :day_trading, :count).and_return(3)
          allow(Position).to receive(:where).and_return(double(sum: 150.0))

          # Mock Rails cache specifically for trading_active
          allow(Rails.cache).to receive(:fetch)
            .with("trading_active", expires_in: 1.hour)
            .and_return(true)

          allow(GoodJob::Job).to receive_message_chain(:where, :order, :first).and_return(nil)
        end

        it "returns bot status information" do
          response = described_class.handle_command(params)

          expect(response[:text]).to include("Bot Status")
          expect(response[:response_type]).to eq("in_channel")
          expect(response[:attachments]).to be_present

          fields = response[:attachments].first[:fields]
          # Test that position count is present and is a number string
          position_field = fields.find { |f| f[:title] == "Open Positions" }
          expect(position_field).to be_present
          expect(position_field[:value]).to match(/^\d+$/)
        end
      end

      describe "/bot-pause command" do
        let(:params) { base_params.merge(command: "/bot-pause", text: "") }

        it "pauses trading and sends notification" do
          expect(described_class).to receive(:set_trading_status).with(false)
          expect(SlackNotificationService).to receive(:bot_status).with(hash_including(
            status: "paused",
            trading_active: false
          ))

          response = described_class.handle_command(params)

          expect(response[:text]).to include("Trading has been paused")
          expect(response[:response_type]).to eq("in_channel")
        end
      end

      describe "/bot-resume command" do
        let(:params) { base_params.merge(command: "/bot-resume", text: "") }

        it "resumes trading and sends notification" do
          expect(described_class).to receive(:set_trading_status).with(true)
          expect(SlackNotificationService).to receive(:bot_status).with(hash_including(
            status: "active",
            trading_active: true
          ))

          response = described_class.handle_command(params)

          expect(response[:text]).to include("Trading has been resumed")
        end
      end

      describe "/bot-positions command" do
        let(:params) { base_params.merge(command: "/bot-positions", text: "open") }
        let(:mock_positions) { [create(:position, product_id: "BTC-USD", side: "LONG")] }

        before do
          allow(described_class).to receive(:get_positions).with("open").and_return(mock_positions)
        end

        it "returns positions information" do
          response = described_class.handle_command(params)

          expect(response[:text]).to include("Current Positions (1)")
          expect(response[:attachments]).to be_present
        end

        it "handles empty positions" do
          allow(described_class).to receive(:get_positions).and_return([])

          response = described_class.handle_command(params)

          expect(response[:text]).to include("No positions found")
          expect(response[:response_type]).to eq("ephemeral")
        end
      end

      describe "/bot-pnl command" do
        let(:params) { base_params.merge(command: "/bot-pnl", text: "today") }

        before do
          allow(described_class).to receive(:get_pnl_data).with("today").and_return({
            total_pnl: 250.0,
            realized_pnl: 200.0,
            unrealized_pnl: 50.0,
            completed_trades: 5,
            win_rate: 80.0,
            best_trade: 100.0
          })
        end

        it "returns PnL report" do
          response = described_class.handle_command(params)

          expect(response[:text]).to include("PnL Report (Today)")
          expect(response[:attachments].first[:color]).to eq("good")

          fields = response[:attachments].first[:fields]
          expect(fields.find { |f| f[:title] == "Total PnL" }[:value]).to eq("$250.0")
        end
      end

      describe "/bot-health command" do
        let(:params) { base_params.merge(command: "/bot-health", text: "") }

        before do
          allow(described_class).to receive(:get_health_status).and_return({
            overall_health: "healthy",
            database: true,
            coinbase_api: true,
            background_jobs: true,
            websocket_connections: 2,
            memory_usage: "45% used"
          })
        end

        it "returns health status" do
          response = described_class.handle_command(params)

          expect(response[:text]).to include("Health Check Report")
          expect(response[:attachments].first[:color]).to eq("good")
        end
      end

      describe "/bot-stop command" do
        let(:params) { base_params.merge(command: "/bot-stop", text: "") }

        before do
          allow(described_class).to receive(:execute_emergency_stop).and_return({
            success: true,
            message: "Emergency stop completed",
            positions_closed: 2,
            orders_cancelled: 1
          })
        end

        it "executes emergency stop" do
          expect(SlackNotificationService).to receive(:alert).with(
            "critical",
            "Emergency Stop Executed",
            anything
          )

          response = described_class.handle_command(params)

          expect(response[:text]).to include("EMERGENCY STOP EXECUTED")
          expect(response[:attachments].first[:color]).to eq("danger")
        end
      end

      describe "/bot-help command" do
        let(:params) { base_params.merge(command: "/bot-help", text: "") }

        it "returns help information" do
          response = described_class.handle_command(params)

          expect(response[:text]).to include("Bot Commands Help")
          expect(response[:response_type]).to eq("ephemeral")
          expect(response[:attachments].first[:fields]).to be_present
        end
      end

      describe "unknown command" do
        let(:params) { base_params.merge(command: "/unknown-command", text: "") }

        it "returns unknown command response" do
          response = described_class.handle_command(params)

          expect(response[:text]).to include("Unknown command")
          expect(response[:response_type]).to eq("ephemeral")
        end
      end

      describe "error handling" do
        let(:params) { base_params.merge(command: "/bot-status", text: "") }

        it "handles errors gracefully" do
          allow(described_class).to receive(:get_bot_status).and_raise(StandardError.new("Test error"))

          response = described_class.handle_command(params)

          expect(response[:text]).to include("Error executing command")
          expect(response[:response_type]).to eq("ephemeral")
        end
      end
    end
  end

  describe "helper methods" do
    describe ".get_bot_status" do
      before do
        # Mock the Position class methods that get_bot_status calls
        allow(Position).to receive_message_chain(:open, :day_trading, :count).and_return(3)
        allow(Position).to receive(:where).and_return(double(sum: 100.0))

        # Mock Rails cache specifically for trading_active
        allow(Rails.cache).to receive(:fetch)
          .with("trading_active", expires_in: 1.hour)
          .and_return(true)

        allow(described_class).to receive(:overall_health_status).and_return("healthy")
        allow(described_class).to receive(:application_uptime).and_return("2h 30m")
      end

      it "returns comprehensive bot status" do
        status = described_class.send(:get_bot_status)

        # Test that the method returns the expected structure
        expect(status).to be_a(Hash)

        # These keys are always present (both success and error cases)
        expect(status).to have_key(:trading_active)
        expect(status).to have_key(:open_positions)
        expect(status).to have_key(:healthy)
        expect(status).to have_key(:health_status)

        # Test that values are of expected types
        expect(status[:trading_active]).to be_in([true, false])
        expect(status[:open_positions]).to be_an(Integer)
        expect(status[:healthy]).to be_in([true, false])
        expect(status[:health_status]).to be_a(String)
      end
    end

    describe ".get_positions" do
      let!(:open_position) { create(:position, product_id: "BTC-USD", status: "OPEN") }
      let!(:closed_position) { create(:position, product_id: "ETH-USD", status: "CLOSED") }

      it "filters positions by status" do
        positions = described_class.send(:get_positions, "open")
        expect(positions).to include(open_position)
        expect(positions).not_to include(closed_position)
      end

      it "defaults to open positions" do
        positions = described_class.send(:get_positions, "")
        expect(positions.count).to eq(Position.open.count)
      end
    end

    describe ".set_trading_status" do
      it "updates trading status in cache" do
        expect(Rails.cache).to receive(:write).with("trading_active", false)

        described_class.send(:set_trading_status, false)
      end

      it "sets emergency flag when specified" do
        expect(Rails.cache).to receive(:write).with("trading_active", false)
        expect(Rails.cache).to receive(:write).with("emergency_stop", true)

        described_class.send(:set_trading_status, false, emergency: true)
      end
    end
  end
end
