# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthCheckJob, type: :job do
  let(:job) { described_class.new }
  let(:logger) { instance_double(Logger) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
  end

  describe "#perform" do
    context "with position type monitoring" do
      let!(:day_position) { create(:position, day_trading: true, status: "OPEN") }
      let!(:swing_position) { create(:position, day_trading: false, status: "OPEN") }
      let!(:old_day_position) { create(:position, day_trading: true, status: "OPEN", entry_time: 25.hours.ago) }

      before do
        allow(ActiveRecord::Base.connection).to receive(:active?).and_return(true)
        # Create comprehensive GoodJob mock
        good_job_relation = double("GoodJobRelation")
        allow(good_job_relation).to receive(:exists?).and_return(true)
        allow(good_job_relation).to receive(:count).and_return(0)
        allow(good_job_relation).to receive(:where).and_return(good_job_relation)
        allow(good_job_relation).to receive(:not).and_return(good_job_relation)
        allow(good_job_relation).to receive(:order).and_return(good_job_relation)
        allow(good_job_relation).to receive(:first).and_return(nil)

        allow(GoodJob::Job).to receive(:where).and_return(good_job_relation)
        allow(GoodJob::CronEntry).to receive(:all).and_return([])
        # Mock Coinbase client with all required methods
        coinbase_client = double("CoinbaseClient")
        allow(coinbase_client).to receive(:test_auth).and_return({advanced_trade: {ok: true}, exchange: {ok: true}})
        allow(coinbase_client).to receive(:futures_balance_summary).and_return({
          "balance_summary" => {
            "total_usd_balance" => "100000.00",
            "total_hold_balance" => "10000.00",
            "available_margin" => "90000.00",
            "initial_margin" => "5000.00"
          }
        })
        allow(coinbase_client).to receive(:futures_margin_window).and_return({
          "margin_window" => {
            "margin_window_type" => "INTRADAY_MARGIN",
            "end_time" => (Time.current + 8.hours).iso8601
          }
        })
        allow(coinbase_client).to receive(:margin_window).and_return({
          "margin_window" => {
            "margin_window_type" => "INTRADAY_MARGIN",
            "end_time" => (Time.current + 8.hours).iso8601
          }
        })

        allow(Coinbase::Client).to receive(:new).and_return(coinbase_client)

        # Mock SwingPositionManager to avoid API calls
        swing_manager = double("SwingPositionManager")
        allow(swing_manager).to receive(:get_swing_position_summary).and_return({
          total_positions: 1,
          total_exposure: 50000.0,
          unrealized_pnl: 100.0,
          risk_metrics: {}
        })
        allow(swing_manager).to receive(:check_swing_risk_limits).and_return({
          risk_status: "acceptable"
        })
        allow(swing_manager).to receive(:positions_approaching_expiry).and_return([])
        allow(swing_manager).to receive(:positions_exceeding_max_hold).and_return([])

        allow(Trading::SwingPositionManager).to receive(:new).and_return(swing_manager)

        # Allow logger debug messages
        allow(logger).to receive(:debug)
      end

      it "counts positions by type correctly" do
        result = job.perform

        expect(result[:open_positions]).to include(
          day_trading: 2,
          swing_trading: 1,
          total: 3
        )
      end

      it "identifies day trading positions needing closure" do
        result = job.perform

        expect(result[:day_trading_positions][:positions_needing_closure]).to eq(1)
        expect(result[:day_trading_positions][:healthy]).to be false
      end

      it "calculates portfolio exposure" do
        result = job.perform

        expect(result[:portfolio_exposure]).to include(
          :day_trading_exposure,
          :swing_trading_exposure,
          :total_exposure
        )
      end
    end

    context "with margin health monitoring" do
      let(:mock_client) { instance_double(Coinbase::Client) }
      let(:balance_summary) do
        {
          "balance_summary" => {
            "initial_margin" => {"value" => "1000.00"},
            "available_margin" => {"value" => "800.00"},
            "liquidation_buffer_percentage" => "15.5",
            "unrealized_pnl" => {"value" => "50.00"},
            "overnight_margin_window_measure" => {"initial_margin" => "200.00"}
          }
        }
      end
      let(:margin_window) do
        {
          "margin_window" => {
            "margin_window_type" => "INTRADAY_MARGIN",
            "end_time" => "2025-01-15T21:00:00Z"
          },
          "is_intraday_margin_killswitch_enabled" => false,
          "is_intraday_margin_enrollment_killswitch_enabled" => false
        }
      end

      before do
        allow(ActiveRecord::Base.connection).to receive(:active?).and_return(true)
        # Create comprehensive GoodJob mock
        good_job_relation = double("GoodJobRelation")
        allow(good_job_relation).to receive(:exists?).and_return(true)
        allow(good_job_relation).to receive(:count).and_return(0)
        allow(good_job_relation).to receive(:where).and_return(good_job_relation)
        allow(good_job_relation).to receive(:not).and_return(good_job_relation)
        allow(good_job_relation).to receive(:order).and_return(good_job_relation)
        allow(good_job_relation).to receive(:first).and_return(nil)

        allow(GoodJob::Job).to receive(:where).and_return(good_job_relation)
        allow(GoodJob::CronEntry).to receive(:all).and_return([])
        allow(Coinbase::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:test_auth).and_return({advanced_trade: {ok: true}, exchange: {ok: true}})
        allow(mock_client).to receive(:futures_balance_summary).and_return(balance_summary)
        allow(mock_client).to receive(:margin_window).and_return(margin_window)
      end

      it "includes margin health data" do
        result = job.perform

        expect(result[:margin_health]).to include(
          :day_trading,
          :swing_trading,
          :overall
        )

        expect(result[:margin_health][:overall]).to include(
          total_margin: "1000.00",
          available_margin: "800.00",
          liquidation_buffer: "15.5",
          unrealized_pnl: "50.00"
        )
      end

      it "includes margin window status" do
        result = job.perform

        expect(result[:margin_window]).to include(
          current_window: "INTRADAY_MARGIN",
          window_end_time: "2025-01-15T21:00:00Z",
          intraday_killswitch: false,
          enrollment_killswitch: false,
          next_transition: a_string_including("overnight margin")
        )
      end
    end

    context "when Coinbase API fails" do
      before do
        allow(ActiveRecord::Base.connection).to receive(:active?).and_return(true)
        # Create comprehensive GoodJob mock
        good_job_relation = double("GoodJobRelation")
        allow(good_job_relation).to receive(:exists?).and_return(true)
        allow(good_job_relation).to receive(:count).and_return(0)
        allow(good_job_relation).to receive(:where).and_return(good_job_relation)
        allow(good_job_relation).to receive(:not).and_return(good_job_relation)
        allow(good_job_relation).to receive(:order).and_return(good_job_relation)
        allow(good_job_relation).to receive(:first).and_return(nil)

        allow(GoodJob::Job).to receive(:where).and_return(good_job_relation)
        allow(GoodJob::CronEntry).to receive(:all).and_return([])
        allow(Coinbase::Client).to receive(:new).and_raise(StandardError.new("API Error"))
      end

      it "handles API failures gracefully" do
        result = job.perform

        expect(result[:margin_health]).to include(error: "API Error", healthy: false)
        expect(result[:margin_window]).to include(error: "API Error", current_window: "unknown")
      end
    end
  end

  describe "#check_portfolio_exposure" do
    let!(:day_position) { create(:position, day_trading: true, status: "OPEN", size: 1, entry_price: 50000) }
    let!(:swing_position) { create(:position, day_trading: false, status: "OPEN", size: 0.5, entry_price: 50000) }

    before do
      # Mock the configuration
      allow(Rails.application.config).to receive(:monitoring_config).and_return({
        max_day_trading_exposure: 0.3,
        max_swing_trading_exposure: 0.2
      })
    end

    it "calculates exposure correctly" do
      result = job.send(:check_portfolio_exposure)

      expect(result).to include(
        :day_trading_exposure,
        :swing_trading_exposure,
        :total_exposure,
        :warnings,
        :healthy
      )
    end

    it "identifies exposure warnings when limits exceeded" do
      # Create positions that would exceed limits
      create(:position, day_trading: true, status: "OPEN", size: 10, entry_price: 50000)

      result = job.send(:check_portfolio_exposure)

      expect(result[:warnings]).not_to be_empty
      expect(result[:healthy]).to be false
    end
  end
end
