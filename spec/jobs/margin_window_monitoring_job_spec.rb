# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarginWindowMonitoringJob, type: :job do
  let(:logger) { instance_double(Logger) }
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(logger).to receive(:debug)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
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
        allow(positions_service).to receive(:send).with(:authenticated_get, "/api/v3/brokerage/cfm/intraday_margin_setting", {})
          .and_return(double(body: margin_window_data.to_json))
        allow(Position).to receive_message_chain(:swing_trading, :open, :includes).and_return([])
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
        allow(positions_service).to receive(:send).and_raise(api_error)
        allow(Sentry).to receive(:with_scope).and_yield(double(set_tag: nil, set_context: nil))
        allow(Sentry).to receive(:capture_exception)
        allow(SlackNotificationService).to receive(:alert)
      end

      it "handles API failures gracefully" do
        expect { described_class.perform_now }.to raise_error(api_error)

        expect(Sentry).to have_received(:capture_exception).with(api_error)
        expect(SlackNotificationService).to have_received(:alert).with(
          "critical",
          "Margin Window Monitoring Job Failed",
          "Critical margin window monitoring job failed: API connection failed"
        )
      end
    end

    context "with swing positions and margin violations" do
      let(:position) { double("Position", id: 1, product_id: "BTC-USD-PERP", size: 10, entry_price: 50000) }
      let(:balance_summary) do
        {
          total_usd_balance: 100000.0,
          available_margin: 5000.0,
          initial_margin: 20000.0
        }
      end
      let(:margin_window_data) do
        {
          "margin_window" => {
            "margin_window_type" => "OVERNIGHT_MARGIN"
          }
        }
      end

      before do
        allow(positions_service).to receive(:instance_variable_get).with(:@authenticated).and_return(true)
        allow(positions_service).to receive(:send).with(:authenticated_get, "/api/v3/brokerage/cfm/intraday_margin_setting", {})
          .and_return(double(body: margin_window_data.to_json))
        allow(positions_service).to receive(:send).with(:authenticated_get, "/api/v3/brokerage/cfm/balance_summary", {})
          .and_return(double(body: balance_summary.to_json))
        allow(Position).to receive_message_chain(:swing_trading, :open, :includes).and_return([position])
        allow(ENV).to receive(:fetch).with("SWING_MARGIN_BUFFER", "0.2").and_return("0.2")
        allow(SlackNotificationService).to receive(:alert)
        allow(Sentry).to receive(:with_scope).and_yield(double(set_tag: nil, set_context: nil))
        allow(Sentry).to receive(:capture_message)
      end

      it "detects margin violations and sends alerts" do
        described_class.perform_now

        expect(SlackNotificationService).to have_received(:alert).with(
          "critical",
          "Swing Position Margin Violations",
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
      let(:position) { double("Position", size: 10, entry_price: 50000) }
      let(:intraday_window) { {"margin_window" => {"margin_window_type" => "INTRADAY_MARGIN"}} }
      let(:overnight_window) { {"margin_window" => {"margin_window_type" => "OVERNIGHT_MARGIN"}} }

      it "calculates higher margin for overnight window" do
        overnight_margin = job_instance.send(:calculate_position_margin_requirement, position, overnight_window)
        intraday_margin = job_instance.send(:calculate_position_margin_requirement, position, intraday_window)

        expect(overnight_margin).to be > intraday_margin
        expect(overnight_margin).to eq(500000 * 0.20) # 20% of position value
        expect(intraday_margin).to eq(500000 * 0.10)  # 10% of position value
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
