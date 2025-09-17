# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarginWindowMonitoringJob, type: :job do
  let(:logger) { instance_double(Logger) }
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }
  let(:advanced_trade_client) { instance_double(Coinbase::AdvancedTradeClient) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(logger).to receive(:debug)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
    allow(Coinbase::AdvancedTradeClient).to receive(:new).with(logger: logger).and_return(advanced_trade_client)
    allow(SentryHelper).to receive(:add_breadcrumb)
  end

  describe "#perform" do
    context "when authentication is available" do
      let(:margin_window_data) do
        {
          "margin_window" => {
            "margin_window_type" => "INTRADAY_MARGIN"
          }
        }
      end

      before do
        allow(positions_service).to receive(:instance_variable_get).with(:@authenticated).and_return(true)
        allow(advanced_trade_client).to receive(:get_current_margin_window).and_return(margin_window_data)
        allow(advanced_trade_client).to receive(:get_futures_balance_summary).and_return({
          "futures_buying_power" => "10000.0",
          "total_usd_balance" => "15000.0",
          "available_margin" => "5000.0",
          "initial_margin" => "2000.0",
          "liquidation_threshold" => "1000.0"
        })
        allow(Position).to receive_message_chain(:swing_trading, :open, :includes).and_return([])
        allow(Rails.cache).to receive(:read).with("last_margin_window_type").and_return(nil)
        allow(Rails.cache).to receive(:write).with("last_margin_window_type", any_args)
        allow(SlackNotificationService).to receive(:alert)
      end

      it "performs margin window monitoring successfully" do
        expect { described_class.perform_now }.not_to raise_error

        expect(logger).to have_received(:info).with("Starting margin window monitoring job")
        expect(logger).to have_received(:info).with("Margin window monitoring job completed successfully")
      end

      it "adds Sentry breadcrumb for start" do
        described_class.perform_now

        expect(SentryHelper).to have_received(:add_breadcrumb).with(
          message: "Margin window monitoring started",
          category: "trading",
          level: "info",
          data: {
            job_type: "margin_window_monitoring",
            critical: true
          }
        )
      end

      context "with intraday margin window" do
        it "handles intraday margin window correctly" do
          described_class.perform_now

          expect(logger).to have_received(:info).with("Intraday margin window active - higher leverage available")
        end

        it "adds breadcrumb for intraday window" do
          described_class.perform_now

          expect(SentryHelper).to have_received(:add_breadcrumb).with(
            message: "Intraday margin window active",
            category: "trading",
            level: "info",
            data: {
              margin_window_type: "intraday",
              higher_leverage: true
            }
          )
        end
      end

      context "with overnight margin window" do
        let(:margin_window_data) do
          {
            "margin_window" => {
              "margin_window_type" => "OVERNIGHT_MARGIN"
            }
          }
        end

        let(:swing_manager) { instance_double(Trading::SwingPositionManager) }

        before do
          allow(Trading::SwingPositionManager).to receive(:new).and_return(swing_manager)
          allow(swing_manager).to receive(:check_swing_risk_limits).and_return({
            risk_status: "violations_detected",
            violations: [{message: "1 swing positions exceed margin requirements"}]
          })
        end

        it "handles overnight margin window correctly" do
          described_class.perform_now

          expect(logger).to have_received(:warn).with("Overnight margin window active - lower leverage, higher margin requirements")
        end

        it "adds breadcrumb for overnight window" do
          described_class.perform_now

          expect(SentryHelper).to have_received(:add_breadcrumb).with(
            message: "Overnight margin window active",
            category: "trading",
            level: "warning",
            data: {
              margin_window_type: "overnight",
              higher_margin_requirements: true
            }
          )
        end
      end
    end

    context "when authentication is not available" do
      before do
        allow(positions_service).to receive(:instance_variable_get).with(:@authenticated).and_return(false)
      end

      it "logs error and returns early" do
        described_class.perform_now

        expect(logger).to have_received(:error).with("Margin window monitoring requires authentication")
      end
    end

    context "when API calls fail" do
      let(:api_error) { StandardError.new("API connection failed") }

      before do
        allow(positions_service).to receive(:instance_variable_get).with(:@authenticated).and_return(true)
        allow(advanced_trade_client).to receive(:get_current_margin_window).and_raise(api_error)
        sentry_scope = double("sentry_scope")
        allow(sentry_scope).to receive(:set_tag)
        allow(sentry_scope).to receive(:set_context)
        allow(sentry_scope).to receive(:set_transaction_name)
        allow(sentry_scope).to receive(:transaction_name)
        allow(sentry_scope).to receive(:transaction_source)
        allow(Sentry).to receive(:with_scope).and_yield(sentry_scope)
        allow(Sentry).to receive(:capture_exception)
        allow(SlackNotificationService).to receive(:alert)
      end

      it "handles API failures gracefully" do
        expect { described_class.perform_now }.to raise_error(api_error)

        expect(Sentry).to have_received(:capture_exception).with(api_error).at_least(:once)
        expect(SlackNotificationService).to have_received(:alert).with(
          "critical",
          "Margin Window Monitoring Job Failed",
          "Critical margin window monitoring job failed: API connection failed"
        )
      end
    end

    context "with swing positions and margin violations" do
      let(:trading_pair) { double("TradingPair", expiration_date: 1.month.from_now) }
      let(:position) do
        double("Position", id: 1, product_id: "BTC-USD-PERP", size: 10, entry_price: 50_000, calculate_pnl: 100.0,
          side: "long", entry_time: Time.current, age_in_hours: 24.5, take_profit: 55_000, stop_loss: 45_000, trading_pair: trading_pair, hit_take_profit?: false, hit_stop_loss?: false)
      end
      let(:balance_summary) do
        {
          total_usd_balance: 100_000.0,
          available_margin: 5000.0,
          initial_margin: 20_000.0
        }
      end
      let(:margin_window_data) do
        {
          "margin_window" => {
            "margin_window_type" => "OVERNIGHT_MARGIN"
          }
        }
      end
      let(:swing_manager) { instance_double(Trading::SwingPositionManager) }

      before do
        allow(positions_service).to receive(:instance_variable_get).with(:@authenticated).and_return(true)
        allow(advanced_trade_client).to receive(:get_current_margin_window).and_return(margin_window_data)
        allow(advanced_trade_client).to receive(:get_futures_balance_summary).and_return(balance_summary)
        allow(Position).to receive_message_chain(:swing_trading, :open, :where, :includes).and_return([position])
        allow(Position).to receive_message_chain(:swing_trading, :open, :includes).and_return([position])
        allow(ENV).to receive(:fetch).with("SWING_MARGIN_BUFFER", "0.2").and_return("0.2")
        allow(Trading::SwingPositionManager).to receive(:new).and_return(swing_manager)
        allow(swing_manager).to receive(:check_swing_risk_limits).and_return({
          risk_status: "violations_detected",
          violations: [{message: "1 swing positions exceed margin requirements"}]
        })
        allow(SlackNotificationService).to receive(:alert)
        sentry_scope = double("sentry_scope")
        allow(sentry_scope).to receive(:set_tag)
        allow(sentry_scope).to receive(:set_context)
        allow(sentry_scope).to receive(:set_transaction_name)
        allow(sentry_scope).to receive(:transaction_name)
        allow(sentry_scope).to receive(:transaction_source)
        allow(Sentry).to receive(:with_scope).and_yield(sentry_scope)
        allow(Sentry).to receive(:capture_message)
      end

      it "detects margin violations and sends alerts" do
        described_class.perform_now

        expect(SlackNotificationService).to have_received(:alert).with(
          "warning",
          "Overnight Margin Compliance Issues",
          match(/1 swing positions exceed margin requirements/)
        )
      end
    end
  end

  describe "queue configuration" do
    it "uses the critical priority queue" do
      expect(described_class.queue_name).to eq("critical")
    end
  end

  describe "private methods" do
    let(:job_instance) { described_class.new }

    before do
      job_instance.instance_variable_set(:@logger, logger)
      job_instance.instance_variable_set(:@positions_service, positions_service)
    end

    describe "#calculate_position_margin_requirement" do
      let(:position) { double("Position", size: 10, entry_price: 50_000) }
      let(:intraday_window) { {"margin_window" => {"margin_window_type" => "INTRADAY_MARGIN"}} }
      let(:overnight_window) { {"margin_window" => {"margin_window_type" => "OVERNIGHT_MARGIN"}} }

      it "calculates higher margin for overnight window" do
        overnight_margin = job_instance.send(:calculate_position_margin_requirement, position, overnight_window)
        intraday_margin = job_instance.send(:calculate_position_margin_requirement, position, intraday_window)

        expect(overnight_margin).to be > intraday_margin
        expect(overnight_margin).to eq(500_000 * 0.20) # 20% of position value
        expect(intraday_margin).to eq(500_000 * 0.10)  # 10% of position value
      end
    end

    describe "#notify_margin_window_change" do
      before do
        allow(Rails.cache).to receive(:read).with("last_margin_window_type").and_return(nil)
        allow(Rails.cache).to receive(:write)
        allow(SlackNotificationService).to receive(:alert)
      end

      it "sends notification for window type changes" do
        margin_window = {"margin_window" => {"margin_window_type" => "OVERNIGHT_MARGIN"}}

        job_instance.send(:notify_margin_window_change, "overnight", margin_window)

        expect(Rails.cache).to have_received(:write).with("last_margin_window_type", "overnight", expires_in: 24.hours)
        expect(SlackNotificationService).to have_received(:alert).with(
          "info",
          "Margin Window Change",
          "Overnight margin window active - reduced leverage, higher margin requirements"
        )
      end

      it "does not send notification if window type hasn't changed" do
        allow(Rails.cache).to receive(:read).with("last_margin_window_type").and_return("overnight")

        margin_window = {"margin_window" => {"margin_window_type" => "OVERNIGHT_MARGIN"}}
        job_instance.send(:notify_margin_window_change, "overnight", margin_window)

        expect(SlackNotificationService).not_to have_received(:alert)
      end
    end
  end
end
