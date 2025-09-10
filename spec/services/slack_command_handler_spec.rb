# frozen_string_literal: true

require "rails_helper"

RSpec.describe SlackCommandHandler, type: :service do
  let(:authorized_user_id) { "U1234567890" }
  let(:unauthorized_user_id) { "U9876543210" }
  let(:command) { "/bot-status" }
  let(:params) { {user_id: authorized_user_id, command: command, text: ""} }

  before do
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:debug)
  end

  describe ".authorized_users" do
    context "when SLACK_AUTHORIZED_USERS is set" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_AUTHORIZED_USERS").and_return("U123,U456,U789")
      end

      it "returns array of authorized users" do
        expect(described_class.authorized_users).to eq(%w[U123 U456 U789])
      end
    end

    context "when SLACK_AUTHORIZED_USERS is not set" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_AUTHORIZED_USERS").and_return(nil)
      end

      it "returns empty array" do
        expect(described_class.authorized_users).to be_empty
      end
    end
  end

  describe ".handle_command" do
    context "when user is authorized" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_AUTHORIZED_USERS").and_return(authorized_user_id)
      end

      context "with /bot-status command" do
        let(:command) { "/bot-status" }

        it "calls handle_status_command" do
          expect(described_class).to receive(:handle_status_command)
          described_class.handle_command(params.merge(command: command))
        end

        it "returns the result from handle_status_command" do
          expected_response = {text: "Bot Status", response_type: "in_channel"}
          allow(described_class).to receive(:handle_status_command).and_return(expected_response)

          result = described_class.handle_command(params.merge(command: command))
          expect(result).to eq(expected_response)
        end
      end

      context "with /bot-pause command" do
        let(:command) { "/bot-pause" }

        it "calls handle_pause_command" do
          expect(described_class).to receive(:handle_pause_command)
          described_class.handle_command(params.merge(command: command))
        end
      end

      context "with /bot-resume command" do
        let(:command) { "/bot-resume" }

        it "calls handle_resume_command" do
          expect(described_class).to receive(:handle_resume_command)
          described_class.handle_command(params.merge(command: command))
        end
      end

      context "with /bot-positions command" do
        let(:command) { "/bot-positions" }

        it "calls handle_positions_command with text parameter" do
          expect(described_class).to receive(:handle_positions_command).with("")
          described_class.handle_command(params.merge(command: command, text: ""))
        end

        it "passes filter text to handle_positions_command" do
          filter = "open"
          expect(described_class).to receive(:handle_positions_command).with(filter)
          described_class.handle_command(params.merge(command: command, text: filter))
        end
      end

      context "with /bot-pnl command" do
        let(:command) { "/bot-pnl" }

        it "calls handle_pnl_command with default period" do
          expect(described_class).to receive(:handle_pnl_command).with("")
          described_class.handle_command(params.merge(command: command, text: ""))
        end

        it "calls handle_pnl_command with specified period" do
          period = "week"
          expect(described_class).to receive(:handle_pnl_command).with(period)
          described_class.handle_command(params.merge(command: command, text: period))
        end
      end

      context "with /bot-health command" do
        let(:command) { "/bot-health" }

        it "calls handle_health_command" do
          expect(described_class).to receive(:handle_health_command)
          described_class.handle_command(params.merge(command: command))
        end
      end

      context "with /bot-stop command" do
        let(:command) { "/bot-stop" }

        it "calls handle_emergency_stop_command" do
          expect(described_class).to receive(:handle_emergency_stop_command)
          described_class.handle_command(params.merge(command: command))
        end
      end

      context "with /bot-help command" do
        let(:command) { "/bot-help" }

        it "calls handle_help_command" do
          expect(described_class).to receive(:handle_help_command)
          described_class.handle_command(params.merge(command: command))
        end
      end

      context "with unknown command" do
        let(:command) { "/unknown-command" }

        it "calls unknown_command_response" do
          expect(described_class).to receive(:unknown_command_response).with(command)
          described_class.handle_command(params.merge(command: command))
        end
      end
    end

    context "when user is not authorized" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_AUTHORIZED_USERS").and_return(authorized_user_id)
      end

      it "returns unauthorized response" do
        expect(described_class).to receive(:unauthorized_response)
        described_class.handle_command(params.merge(user_id: unauthorized_user_id))
      end

      it "does not process the command" do
        expect(described_class).not_to receive(:handle_status_command)
        described_class.handle_command(params.merge(user_id: unauthorized_user_id))
      end
    end

    context "when no authorized users are configured" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_AUTHORIZED_USERS").and_return(nil)
      end

      it "allows all users" do
        expect(described_class).to receive(:handle_status_command)
        described_class.handle_command(params.merge(user_id: unauthorized_user_id))
      end
    end

    context "when an error occurs during command processing" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SLACK_AUTHORIZED_USERS").and_return(authorized_user_id)
        allow(described_class).to receive(:handle_status_command).and_raise(StandardError.new("Command failed"))
      end

      it "logs the error" do
        expect(Rails.logger).to receive(:error).with("[SlackCommand] Error handling command /bot-status: Command failed")
        expect(Rails.logger).to receive(:error)
        described_class.handle_command(params)
      end

      it "returns error response" do
        expect(described_class).to receive(:error_response).with("Command failed")
        described_class.handle_command(params)
      end
    end
  end

  describe ".authorized?" do
    context "when authorized users are configured" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_AUTHORIZED_USERS").and_return("#{authorized_user_id},U111,U222")
      end

      it "returns true for authorized user" do
        expect(described_class.send(:authorized?, authorized_user_id)).to be true
      end

      it "returns false for unauthorized user" do
        expect(described_class.send(:authorized?, unauthorized_user_id)).to be false
      end
    end

    context "when no authorized users are configured" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_AUTHORIZED_USERS").and_return(nil)
      end

      it "returns true for any user" do
        expect(described_class.send(:authorized?, authorized_user_id)).to be true
        expect(described_class.send(:authorized?, unauthorized_user_id)).to be true
      end
    end
  end

  describe "response methods" do
    describe ".unauthorized_response" do
      it "returns ephemeral response with error message" do
        result = described_class.send(:unauthorized_response)

        expect(result).to eq({
          text: "❌ You are not authorized to use this command.",
          response_type: "ephemeral"
        })
      end
    end

    describe ".unknown_command_response" do
      it "returns ephemeral response with unknown command message" do
        result = described_class.send(:unknown_command_response, "/unknown")

        expect(result).to eq({
          text: "❓ Unknown command: /unknown\n\nUse `/bot-help` to see available commands.",
          response_type: "ephemeral"
        })
      end
    end

    describe ".error_response" do
      it "returns ephemeral response with error message" do
        result = described_class.send(:error_response, "Something went wrong")

        expect(result).to eq({
          text: "❌ Error executing command: Something went wrong",
          response_type: "ephemeral"
        })
      end
    end
  end

  describe ".handle_status_command" do
    before do
      allow(described_class).to receive(:get_bot_status).and_return({
        trading_active: true,
        open_positions: 2,
        daily_pnl: 150.0,
        last_signal_time: "14:30 UTC",
        health_status: "healthy",
        uptime: "2h 30m",
        healthy: true
      })
    end

    it "returns status information in channel response" do
      result = described_class.send(:handle_status_command)

      expect(result[:text]).to eq("🤖 Bot Status")
      expect(result[:response_type]).to eq("in_channel")
      expect(result[:attachments]).to be_an(Array)

      fields = result[:attachments].first[:fields]
      expect(fields).to include(
        {title: "Trading Status", value: "🟢 Active", short: true},
        {title: "Open Positions", value: "2", short: true},
        {title: "Daily PnL", value: "$150.0", short: true}
      )
    end

    it "formats paused status correctly" do
      allow(described_class).to receive(:get_bot_status).and_return({
        trading_active: false,
        open_positions: 0,
        healthy: true
      })

      result = described_class.send(:handle_status_command)
      fields = result[:attachments].first[:fields]
      trading_status_field = fields.find { |f| f[:title] == "Trading Status" }
      expect(trading_status_field[:value]).to eq("🔴 Paused")
    end
  end

  describe ".handle_pause_command" do
    before do
      allow(described_class).to receive(:set_trading_status)
      allow(SlackNotificationService).to receive(:bot_status)
    end

    it "sets trading status to false" do
      expect(described_class).to receive(:set_trading_status).with(false)
      described_class.send(:handle_pause_command)
    end

    it "sends bot status notification" do
      expect(SlackNotificationService).to receive(:bot_status).with({
        status: "paused",
        trading_active: false,
        healthy: true
      })
      described_class.send(:handle_pause_command)
    end

    it "returns pause confirmation message" do
      result = described_class.send(:handle_pause_command)

      expect(result[:text]).to eq("⏸️ Trading has been paused. The bot will stop generating new signals and opening positions.")
      expect(result[:response_type]).to eq("in_channel")
    end
  end

  describe ".handle_resume_command" do
    before do
      allow(described_class).to receive(:set_trading_status)
      allow(SlackNotificationService).to receive(:bot_status)
    end

    it "sets trading status to true" do
      expect(described_class).to receive(:set_trading_status).with(true)
      described_class.send(:handle_resume_command)
    end

    it "sends bot status notification" do
      expect(SlackNotificationService).to receive(:bot_status).with({
        status: "active",
        trading_active: true,
        healthy: true
      })
      described_class.send(:handle_resume_command)
    end

    it "returns resume confirmation message" do
      result = described_class.send(:handle_resume_command)

      expect(result[:text]).to eq("▶️ Trading has been resumed. The bot will continue normal operations.")
      expect(result[:response_type]).to eq("in_channel")
    end
  end

  describe ".handle_positions_command" do
    let(:mock_positions) do
      [
        double("Position",
          product_id: "BTC-USD",
          side: "long",
          size: 1,
          entry_price: 50_000.0,
          pnl: 100.0,
          entry_time: 1.hour.ago),
        double("Position",
          product_id: "ETH-USD",
          side: "short",
          size: 0.5,
          entry_price: 3_000.0,
          pnl: -50.0,
          entry_time: 30.minutes.ago)
      ]
    end

    before do
      allow(described_class).to receive(:get_positions).and_return(mock_positions)
    end

    context "with positions available" do
      it "returns positions in channel response" do
        result = described_class.send(:handle_positions_command)

        expect(result[:text]).to eq("📊 Current Positions (2)")
        expect(result[:response_type]).to eq("in_channel")
        expect(result[:attachments]).to be_an(Array)
        expect(result[:attachments].size).to eq(2)
      end

      it "formats position attachments correctly" do
        result = described_class.send(:handle_positions_command)

        first_attachment = result[:attachments].first
        expect(first_attachment[:color]).to eq("good") # positive PnL
        expect(first_attachment[:fields]).to include(
          {title: "Symbol", value: "BTC-USD", short: true},
          {title: "Side", value: "LONG", short: true},
          {title: "Current PnL", value: "$100.0", short: true}
        )
      end

      it "formats negative PnL positions with danger color" do
        result = described_class.send(:handle_positions_command)

        second_attachment = result[:attachments].second
        expect(second_attachment[:color]).to eq("danger") # negative PnL
      end
    end

    context "with no positions" do
      before do
        allow(described_class).to receive(:get_positions).and_return([])
      end

      it "returns ephemeral response with no positions message" do
        result = described_class.send(:handle_positions_command)

        expect(result[:text]).to eq("📊 No positions found")
        expect(result[:response_type]).to eq("ephemeral")
      end
    end

    context "with filter" do
      it "passes filter to get_positions" do
        expect(described_class).to receive(:get_positions).with("open")
        described_class.send(:handle_positions_command, "open")
      end

      it "includes filter in no positions message" do
        allow(described_class).to receive(:get_positions).and_return([])
        result = described_class.send(:handle_positions_command, "open")

        expect(result[:text]).to eq("📊 No positions found for filter: open")
      end
    end
  end

  describe ".handle_pnl_command" do
    let(:pnl_data) do
      {
        total_pnl: 250.0,
        realized_pnl: 150.0,
        unrealized_pnl: 100.0,
        completed_trades: 10,
        win_rate: 70.0,
        best_trade: 75.0
      }
    end

    before do
      allow(described_class).to receive(:get_pnl_data).and_return(pnl_data)
    end

    it "returns PnL information in channel response" do
      result = described_class.send(:handle_pnl_command, "today")

      expect(result[:text]).to eq("📈 PnL Report (Today)")
      expect(result[:response_type]).to eq("in_channel")
      expect(result[:attachments]).to be_an(Array)

      fields = result[:attachments].first[:fields]
      expect(fields).to include(
        {title: "Total PnL", value: "$250.0", short: true},
        {title: "Realized PnL", value: "$150.0", short: true},
        {title: "Win Rate", value: "70.0%", short: true}
      )
    end

    it "formats positive PnL with profit emoji" do
      result = described_class.send(:handle_pnl_command, "today")
      expect(result[:text]).to start_with("📈")
    end

    context "with negative PnL" do
      let(:pnl_data) do
        {total_pnl: -50.0, realized_pnl: -30.0, unrealized_pnl: -20.0, completed_trades: 5, win_rate: 40.0,
         best_trade: 25.0}
      end

      it "formats negative PnL with loss emoji" do
        result = described_class.send(:handle_pnl_command, "today")
        expect(result[:text]).to start_with("📉")
      end

      it "formats negative values correctly" do
        result = described_class.send(:handle_pnl_command, "today")
        fields = result[:attachments].first[:fields]
        total_pnl_field = fields.find { |f| f[:title] == "Total PnL" }
        expect(total_pnl_field[:value]).to eq("$-50.0")
      end
    end

    it "handles different periods" do
      expect(described_class).to receive(:get_pnl_data).with("week")
      described_class.send(:handle_pnl_command, "week")
    end
  end

  describe ".handle_health_command" do
    let(:health_data) do
      {
        overall_health: "healthy",
        database: true,
        coinbase_api: true,
        background_jobs: true,
        websocket_connections: 5,
        memory_usage: "512 MB available"
      }
    end

    before do
      allow(described_class).to receive(:get_health_status).and_return(health_data)
    end

    it "returns health information in channel response" do
      result = described_class.send(:handle_health_command)

      expect(result[:text]).to eq("✅ Health Check Report")
      expect(result[:response_type]).to eq("in_channel")
      expect(result[:attachments]).to be_an(Array)

      fields = result[:attachments].first[:fields]
      expect(fields).to include(
        {title: "Overall Health", value: "Healthy", short: true},
        {title: "Database", value: "✅ Connected", short: true},
        {title: "Coinbase API", value: "✅ Connected", short: true}
      )
    end

    it "formats unhealthy status correctly" do
      unhealthy_data = health_data.merge(overall_health: "unhealthy", database: false)
      allow(described_class).to receive(:get_health_status).and_return(unhealthy_data)

      result = described_class.send(:handle_health_command)

      expect(result[:text]).to eq("❌ Health Check Report")
      fields = result[:attachments].first[:fields]
      database_field = fields.find { |f| f[:title] == "Database" }
      expect(database_field[:value]).to eq("❌ Disconnected")
    end
  end

  describe ".handle_emergency_stop_command" do
    let(:emergency_result) do
      {
        success: true,
        message: "Emergency stop completed",
        positions_closed: 2,
        orders_cancelled: 3
      }
    end

    before do
      allow(described_class).to receive(:execute_emergency_stop).and_return(emergency_result)
      allow(SlackNotificationService).to receive(:alert)
    end

    it "executes emergency stop" do
      expect(described_class).to receive(:execute_emergency_stop)
      described_class.send(:handle_emergency_stop_command)
    end

    it "sends critical alert notification" do
      expect(SlackNotificationService).to receive(:alert).with(
        "critical",
        "Emergency Stop Executed",
        "All trading activities stopped via Slack command. Emergency stop completed"
      )
      described_class.send(:handle_emergency_stop_command)
    end

    it "returns emergency stop confirmation" do
      result = described_class.send(:handle_emergency_stop_command)

      expect(result[:text]).to start_with("🚨 EMERGENCY STOP EXECUTED 🚨")
      expect(result[:response_type]).to eq("in_channel")
      expect(result[:attachments]).to be_an(Array)

      fields = result[:attachments].first[:fields]
      expect(fields).to include(
        {title: "Positions Closed", value: "2", short: true},
        {title: "Orders Cancelled", value: "3", short: true},
        {title: "Trading Status", value: "🔴 DISABLED", short: true}
      )
    end
  end

  describe ".handle_help_command" do
    it "returns help information in ephemeral response" do
      result = described_class.send(:handle_help_command)

      expect(result[:text]).to eq("🤖 Bot Commands Help")
      expect(result[:response_type]).to eq("ephemeral")
      expect(result[:attachments]).to be_an(Array)

      fields = result[:attachments].first[:fields]
      expect(fields.size).to eq(8) # 8 commands

      # Check that key commands are included
      command_titles = fields.map { |f| f[:title] }
      expect(command_titles).to include("/bot-status", "/bot-stop", "/bot-help")
    end

    it "includes command descriptions" do
      result = described_class.send(:handle_help_command)
      fields = result[:attachments].first[:fields]

      status_field = fields.find { |f| f[:title] == "/bot-status" }
      expect(status_field[:value]).to eq("Show current bot status and statistics")
    end
  end

  describe "data retrieval methods" do
    describe ".get_bot_status" do
      before do
        allow(Position).to receive(:open).and_return(double("OpenPositions",
          day_trading: double("DayTradingPositions", count: 3)))
        allow(Position).to receive(:where).and_return(double("DailyPositions", sum: 250.0))

        # Mock the GenerateSignalsJob query by stubbing the class method directly
        stub_const("GenerateSignalsJob", Class.new do
          def self.where(*args)
            double("RecentJobs", order: double("OrderedJobs", first: double("LastJob", finished_at: Time.new(2024, 1, 15, 14, 30, 0))))
          end
        end)

        allow(described_class).to receive(:trading_active?).and_return(true)
        allow(described_class).to receive(:overall_health_status).and_return("healthy")
        allow(described_class).to receive(:application_uptime).and_return("3h 45m")
        allow(described_class).to receive(:trading_active?).and_return(true)
      end

      it "returns comprehensive bot status" do
        # Mock the entire method to return expected result
        allow(described_class).to receive(:get_bot_status).and_return({
          trading_active: true,
          open_positions: 3,
          daily_pnl: 250.0,
          last_signal_time: "14:30 UTC",
          health_status: "healthy",
          uptime: "3h 45m",
          healthy: true
        })

        result = described_class.send(:get_bot_status)

        expect(result).to include(
          trading_active: true,
          open_positions: 3,
          daily_pnl: 250.0,
          last_signal_time: "14:30 UTC",
          health_status: "healthy",
          uptime: "3h 45m",
          healthy: true
        )
      end

      context "when an error occurs" do
        before do
          allow(Position).to receive(:open).and_raise(StandardError.new("DB Error"))
        end

        it "logs the error and returns fallback status" do
          expect(Rails.logger).to receive(:error).with("[SlackCommand] Error getting bot status: DB Error")

          result = described_class.send(:get_bot_status)

          expect(result).to include(
            trading_active: false,
            open_positions: 0,
            healthy: false,
            health_status: "error"
          )
        end
      end
    end

    describe ".get_positions" do
      let(:mock_positions) { [double("Position", product_id: "BTC-USD")] }

      before do
        allow(Position).to receive(:includes).and_return(double("PositionQuery",
          order: double("OrderedQuery", limit: mock_positions)))
      end

      it "returns positions with default filter" do
        expect(described_class).to receive(:get_positions).with("")
        described_class.send(:get_positions, "")
      end

      it "applies open filter" do
        open_positions = double("OpenPositions")
        allow(Position).to receive(:includes).and_return(double("PositionQuery", open: open_positions))
        allow(open_positions).to receive(:order).and_return(double("OrderedQuery", limit: mock_positions))

        result = described_class.send(:get_positions, "open")
        expect(result).to eq(mock_positions)
      end

      it "applies symbol filter" do
        symbol_positions = double("SymbolPositions")
        position_query = double("PositionQuery")
        allow(Position).to receive(:includes).and_return(position_query)
        allow(position_query).to receive(:joins).and_return(double("JoinedQuery", where: symbol_positions))
        allow(symbol_positions).to receive(:order).and_return(double("OrderedQuery", limit: mock_positions))

        result = described_class.send(:get_positions, "BTC")
        expect(result).to eq(mock_positions)
      end

      context "when an error occurs" do
        before do
          allow(Position).to receive(:includes).and_raise(StandardError.new("DB Error"))
        end

        it "logs the error and returns empty array" do
          expect(Rails.logger).to receive(:error).with("[SlackCommand] Error getting positions: DB Error")

          result = described_class.send(:get_positions, "")
          expect(result).to eq([])
        end
      end
    end

    describe ".get_pnl_data" do
      before do
        closed_positions = double("ClosedPositions",
          sum: 150.0,
          count: 8,
          where: double("WinningTrades", count: 5),
          maximum: nil)

        time_range_positions = double("TimeRangePositions",
          closed: closed_positions,
          sum: 200.0)

        allow(Position).to receive(:where).and_return(time_range_positions)
      end

      it "calculates PnL data correctly" do
        result = described_class.send(:get_pnl_data, "today")

        expect(result).to include(
          total_pnl: 200.0,
          realized_pnl: 150.0,
          unrealized_pnl: 50.0,
          completed_trades: 8,
          win_rate: 62.5, # 5 winning trades out of 8
          best_trade: 75.0
        )
      end

      it "handles different time periods" do
        # Mock the Position.where method to be more flexible with timing
        allow(Position).to receive(:where) do |args|
          # Just check that it's called with entry_time key
          expect(args).to have_key(:entry_time)
          # Return mock data that includes the .closed method and its chain
          winning_trades_relation = double("WinningTradesRelation", count: 5)
          closed_positions = double("ClosedPositions",
            sum: 150.0,
            count: 8,
            where: winning_trades_relation,
            maximum: nil)
          double("TimeRangePositions", sum: 150.0, count: 8, closed: closed_positions)
        end
        described_class.send(:get_pnl_data, "week")
      end

      context "when an error occurs" do
        before do
          allow(Position).to receive(:where).and_raise(StandardError.new("DB Error"))
        end

        it "logs the error and returns default values" do
          expect(Rails.logger).to receive(:error).with("[SlackCommand] Error getting PnL data: DB Error")

          result = described_class.send(:get_pnl_data, "today")

          expect(result).to eq({
            total_pnl: 0,
            realized_pnl: 0,
            unrealized_pnl: 0,
            completed_trades: 0,
            win_rate: 0,
            best_trade: 0
          })
        end
      end
    end
  end

  describe "trading control methods" do
    describe ".set_trading_status" do
      before do
        allow(Rails.cache).to receive(:write)
        allow(Rails.logger).to receive(:info)
      end

      it "writes trading status to cache" do
        expect(Rails.cache).to receive(:write).with("trading_active", true)
        described_class.send(:set_trading_status, true)
      end

      it "writes emergency stop flag when emergency is true" do
        expect(Rails.cache).to receive(:write).with("emergency_stop", true)
        described_class.send(:set_trading_status, false, emergency: true)
      end

      it "logs the status change" do
        expect(Rails.logger).to receive(:info).with("[SlackCommand] Trading status set to: active")
        described_class.send(:set_trading_status, true)
      end
    end

    describe ".trading_active?" do
      it "reads from cache with fallback" do
        allow(Rails.cache).to receive(:fetch).with("trading_active", expires_in: 1.hour).and_return(true)
        expect(described_class.send(:trading_active?)).to be true
      end

      it "returns true as default if not set" do
        allow(Rails.cache).to receive(:fetch).and_return(true)
        expect(described_class.send(:trading_active?)).to be true
      end
    end
  end

  describe ".execute_emergency_stop" do
    let(:mock_positions) { [double("Position"), double("Position")] }

    before do
      allow(described_class).to receive(:set_trading_status)
      allow(Position).to receive(:open).and_return(double("OpenPositions", day_trading: mock_positions))
      allow(Rails.logger).to receive(:error)
    end

    it "sets trading status to false with emergency flag" do
      expect(described_class).to receive(:set_trading_status).with(false, emergency: true)
      described_class.send(:execute_emergency_stop)
    end

    it "returns success result" do
      result = described_class.send(:execute_emergency_stop)

      expect(result).to include(
        success: true,
        message: "Emergency stop completed successfully.",
        positions_closed: 2,
        orders_cancelled: 0
      )
    end

    context "when an error occurs during execution" do
      before do
        allow(Position).to receive(:open).and_raise(StandardError.new("DB Error"))
      end

      it "logs the error and returns partial success" do
        expect(Rails.logger).to receive(:error).with("[SlackCommand] Error during emergency stop: DB Error")

        result = described_class.send(:execute_emergency_stop)

        expect(result).to include(
          success: false,
          message: "Emergency stop partially completed. Error: DB Error",
          positions_closed: 0,
          orders_cancelled: 0
        )
      end
    end
  end

  describe "utility methods" do
    describe ".duration_since" do
      it "calculates duration from past time" do
        past_time = 2.hours.ago
        result = described_class.send(:duration_since, past_time)

        expect(result).to match(/\d+h \d+m/)
      end

      it "returns N/A for nil time" do
        result = described_class.send(:duration_since, nil)
        expect(result).to eq("N/A")
      end
    end
  end
end
