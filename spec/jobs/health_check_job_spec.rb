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
    allow(SlackNotificationService).to receive(:health_check)
    allow(SlackNotificationService).to receive(:alert)
    allow(Rails.cache).to receive(:write)
  end

  describe "#perform" do
    context "when all health checks pass" do
      before do
        allow(job).to receive(:gather_health_data).and_return({
          database: true,
          coinbase_api: true,
          background_jobs: true,
          websocket_connections: 5,
          memory_usage: "45.2% used (3.6 GB / 8 GB)",
          trading_active: true,
          recent_signals: Time.current,
          open_positions: 2,
          overall_health: "healthy"
        })
      end

      it "logs the start and completion of health check" do
        expect(logger).to receive(:info).with("Starting health check job")
        expect(logger).to receive(:info).with("Completed health check job")

        job.perform
      end

      it "gathers health data" do
        expect(job).to receive(:gather_health_data)

        job.perform
      end

      it "logs health check results" do
        expect(logger).to receive(:info).with(/Health check results:/)

        job.perform
      end

      it "caches health data" do
        expect(Rails.cache).to receive(:write).with(
          "last_health_check",
          {
            timestamp: anything,
            data: anything
          },
          expires_in: 1.hour
        )

        job.perform
      end

      it "returns health data" do
        result = job.perform
        expect(result).to be_a(Hash)
        expect(result[:overall_health]).to eq("healthy")
      end

      context "when send_slack_notification is false" do
        it "does not send Slack notification for healthy status" do
          expect(SlackNotificationService).not_to receive(:health_check)

          job.perform(send_slack_notification: false)
        end
      end

      context "when send_slack_notification is true" do
        it "sends Slack notification" do
          expect(SlackNotificationService).to receive(:health_check)

          job.perform(send_slack_notification: true)
        end
      end
    end

    context "when health checks fail" do
      before do
        allow(job).to receive(:gather_health_data).and_return({
          database: true,
          coinbase_api: false,
          background_jobs: false,
          websocket_connections: 0,
          memory_usage: "95% used",
          trading_active: false,
          recent_signals: false,
          open_positions: 0,
          overall_health: "unhealthy"
        })
      end

      it "sends Slack notification when overall health is not healthy" do
        expect(SlackNotificationService).to receive(:health_check)

        job.perform(send_slack_notification: false)
      end
    end

    context "when an error occurs" do
      before do
        allow(job).to receive(:gather_health_data).and_raise(StandardError.new("Test error"))
        allow(job).to receive(:gather_health_data).and_raise(StandardError.new("Test error"))
      end

      it "logs the error" do
        expect(logger).to receive(:error).with("Health check job failed: Test error")
        expect(logger).to receive(:error)

        expect { job.perform }.to raise_error(StandardError, "Test error")
      end

      it "sends error notification to Slack" do
        expect(SlackNotificationService).to receive(:alert).with(
          "error",
          "Health Check Failed",
          "Health check job encountered an error: Test error"
        )

        expect { job.perform }.to raise_error(StandardError, "Test error")
      end

      it "tries to gather partial health data for Sentry context" do
        expect(job).to receive(:gather_health_data).twice

        expect { job.perform }.to raise_error(StandardError, "Test error")
      end

      it "re-raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Test error")
      end
    end
  end

  describe "#gather_health_data" do
    it "returns a hash with all health check results" do
      allow(job).to receive(:check_database_health).and_return(true)
      allow(job).to receive(:check_coinbase_api_health).and_return(true)
      allow(job).to receive(:check_background_jobs_health).and_return(true)
      allow(job).to receive(:count_websocket_connections).and_return(5)
      allow(job).to receive(:get_memory_usage).and_return("45% used")
      allow(job).to receive(:check_trading_status).and_return(true)
      allow(job).to receive(:check_recent_signals).and_return(Time.current)
      allow(job).to receive(:count_open_positions).and_return(2)
      allow(job).to receive(:check_swing_positions_health).and_return({healthy: true, total_positions: 0})

      result = job.send(:gather_health_data)

      expect(result).to be_a(Hash)
      expect(result).to have_key(:database)
      expect(result).to have_key(:coinbase_api)
      expect(result).to have_key(:background_jobs)
      expect(result).to have_key(:websocket_connections)
      expect(result).to have_key(:memory_usage)
      expect(result).to have_key(:trading_active)
      expect(result).to have_key(:recent_signals)
      expect(result).to have_key(:open_positions)
      expect(result).to have_key(:swing_positions)
      expect(result).to have_key(:overall_health)
    end

    it "calls all health check methods" do
      expect(job).to receive(:check_database_health)
      expect(job).to receive(:check_coinbase_api_health)
      expect(job).to receive(:check_background_jobs_health)
      expect(job).to receive(:count_websocket_connections)
      expect(job).to receive(:get_memory_usage)
      expect(job).to receive(:check_trading_status)
      expect(job).to receive(:check_recent_signals)
      expect(job).to receive(:count_open_positions)
      expect(job).to receive(:check_swing_positions_health)
      expect(job).to receive(:calculate_overall_health)

      job.send(:gather_health_data)
    end
  end

  describe "#check_database_health" do
    context "when database is healthy" do
      before do
        allow(ActiveRecord::Base.connection).to receive(:active?).and_return(true)
      end

      it "returns true" do
        expect(job.send(:check_database_health)).to be true
      end
    end

    context "when database connection fails" do
      before do
        allow(ActiveRecord::Base.connection).to receive(:active?).and_raise(StandardError.new("Connection failed"))
      end

      it "returns false" do
        expect(job.send(:check_database_health)).to be false
      end
    end
  end

  describe "#check_coinbase_api_health" do
    let(:mock_client) { instance_double(Coinbase::Client) }
    let(:mock_result) do
      {
        advanced_trade: {ok: true},
        exchange: {ok: true}
      }
    end

    before do
      allow(Coinbase::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:test_auth).and_return(mock_result)
    end

    context "when API is healthy" do
      it "returns true" do
        expect(job.send(:check_coinbase_api_health)).to be true
      end
    end

    context "when advanced trade API fails" do
      let(:mock_result) do
        {
          advanced_trade: {ok: false},
          exchange: {ok: true}
        }
      end

      it "returns false" do
        expect(job.send(:check_coinbase_api_health)).to be false
      end
    end

    context "when exchange API fails" do
      let(:mock_result) do
        {
          advanced_trade: {ok: true},
          exchange: {ok: false}
        }
      end

      it "returns false" do
        expect(job.send(:check_coinbase_api_health)).to be false
      end
    end

    context "when API call raises error" do
      before do
        allow(mock_client).to receive(:test_auth).and_raise(StandardError.new("API timeout"))
      end

      it "logs warning and returns false" do
        expect(logger).to receive(:warn).with("Coinbase API health check failed: API timeout")
        expect(job.send(:check_coinbase_api_health)).to be false
      end
    end
  end

  describe "#check_background_jobs_health" do
    context "when background jobs are healthy" do
      before do
        allow(GoodJob::Job).to receive(:where).and_return(double(exists?: true))
        allow(GoodJob::CronEntry).to receive(:all).and_return([
          double(job_class: "GenerateSignalsJob"),
          double(job_class: "DayTradingPositionManagementJob")
        ])
      end

      it "returns true" do
        expect(job.send(:check_background_jobs_health)).to be true
      end
    end

    context "when no recent jobs processed" do
      before do
        allow(GoodJob::Job).to receive(:where).and_return(double(exists?: false))
        allow(GoodJob::CronEntry).to receive(:all).and_return([double(job_class: "GenerateSignalsJob")])
      end

      it "returns false" do
        expect(job.send(:check_background_jobs_health)).to be false
      end
    end

    context "when critical jobs are not scheduled" do
      before do
        allow(GoodJob::Job).to receive(:where).and_return(double(exists?: true))
        allow(GoodJob::CronEntry).to receive(:all).and_return([double(job_class: "SomeOtherJob")])
      end

      it "returns false" do
        expect(job.send(:check_background_jobs_health)).to be false
      end
    end

    context "when error occurs" do
      before do
        allow(GoodJob::Job).to receive(:where).and_raise(StandardError.new("DB error"))
      end

      it "logs warning and returns false" do
        expect(logger).to receive(:warn).with("Background jobs health check failed: DB error")
        expect(job.send(:check_background_jobs_health)).to be false
      end
    end
  end

  describe "#count_websocket_connections" do
    it "returns 0 as placeholder" do
      expect(job.send(:count_websocket_connections)).to eq(0)
    end
  end

  describe "#get_memory_usage" do
    context "when /proc/meminfo is readable" do
      let(:meminfo_content) do
        <<~MEMINFO
          MemTotal:        8192000 kB
          MemAvailable:    4096000 kB
        MEMINFO
      end

      before do
        allow(File).to receive(:readable?).with("/proc/meminfo").and_return(true)
        allow(File).to receive(:read).with("/proc/meminfo").and_return(meminfo_content)
      end

      it "calculates memory usage correctly" do
        result = job.send(:get_memory_usage)
        expect(result).to include("50.0% used")
        expect(result).to include("4000 MB")
        expect(result).to include("8000 MB")
      end
    end

    context "when /proc/meminfo is not readable" do
      before do
        allow(File).to receive(:readable?).with("/proc/meminfo").and_return(false)
      end

      it "returns unavailable message" do
        expect(job.send(:get_memory_usage)).to eq("Memory info not available")
      end
    end

    context "when parsing fails" do
      before do
        allow(File).to receive(:readable?).with("/proc/meminfo").and_return(true)
        allow(File).to receive(:read).with("/proc/meminfo").and_return("Invalid content")
      end

      it "returns unable to parse message" do
        expect(job.send(:get_memory_usage)).to eq("Unable to parse /proc/meminfo")
      end
    end

    context "when error occurs" do
      before do
        allow(File).to receive(:readable?).with("/proc/meminfo").and_return(true)
        allow(File).to receive(:read).with("/proc/meminfo").and_raise(StandardError.new("Permission denied"))
      end

      it "logs warning and returns error message" do
        expect(logger).to receive(:warn).with("Memory usage check failed: Permission denied")
        expect(job.send(:get_memory_usage)).to eq("Error reading memory info")
      end
    end
  end

  describe "#check_trading_status" do
    it "returns cached trading active status" do
      expect(Rails.cache).to receive(:fetch).with("trading_active", expires_in: 1.hour).and_return(true)

      expect(job.send(:check_trading_status)).to be true
    end
  end

  describe "#check_recent_signals" do
    context "when recent signal job exists" do
      let(:finished_at) { 30.minutes.ago }

      before do
        allow(GoodJob::Job).to receive(:where).and_return(double(order: double(first: double(finished_at: finished_at))))
      end

      it "returns the finished_at timestamp" do
        expect(job.send(:check_recent_signals)).to eq(finished_at)
      end
    end

    context "when no recent signal job exists" do
      before do
        allow(GoodJob::Job).to receive(:where).and_return(double(order: double(first: nil)))
      end

      it "returns false" do
        expect(job.send(:check_recent_signals)).to be false
      end
    end
  end

  describe "#count_open_positions" do
    context "when positions can be counted" do
      before do
        # Mock the Position.open scope chain
        open_scope = double("open_scope")
        allow(Position).to receive(:open).and_return(open_scope)
        allow(open_scope).to receive(:count).and_return(5)
        allow(open_scope).to receive(:day_trading).and_return(double(count: 3))
        allow(open_scope).to receive(:swing_trading).and_return(double(count: 2))
      end

      it "returns the count of open positions" do
        result = job.send(:count_open_positions)
        expect(result).to eq({
          day_trading: 3,
          swing_trading: 2,
          total: 5
        })
      end
    end

    context "when error occurs" do
      before do
        allow(Position).to receive(:open).and_raise(StandardError.new("DB error"))
      end

      it "returns 0" do
        result = job.send(:count_open_positions)
        expect(result).to eq({
          day_trading: 0,
          swing_trading: 0,
          total: 0
        })
      end
    end
  end

  describe "#calculate_overall_health" do
    context "when all checks pass" do
      let(:checks) do
        {
          database: true,
          coinbase_api: true,
          background_jobs: true,
          websocket_connections: 5,
          memory_usage: "45% used",
          trading_active: true,
          recent_signals: Time.current,
          open_positions: 2
        }
      end

      it 'returns "healthy"' do
        expect(job.send(:calculate_overall_health, checks)).to eq("healthy")
      end
    end

    context "when critical checks fail" do
      let(:checks) do
        {
          database: false,
          coinbase_api: true,
          background_jobs: true,
          websocket_connections: 5,
          memory_usage: "45% used",
          trading_active: true,
          recent_signals: Time.current,
          open_positions: 2
        }
      end

      it 'returns "unhealthy"' do
        expect(job.send(:calculate_overall_health, checks)).to eq("unhealthy")
      end
    end

    context "when important checks fail but critical pass" do
      let(:checks) do
        {
          database: true,
          coinbase_api: false,
          background_jobs: true,
          websocket_connections: 5,
          memory_usage: "45% used",
          trading_active: true,
          recent_signals: Time.current,
          open_positions: 2
        }
      end

      it 'returns "warning"' do
        expect(job.send(:calculate_overall_health, checks)).to eq("warning")
      end
    end
  end

  describe "job configuration" do
    it "uses the default queue" do
      expect(described_class.queue_name).to eq("default")
    end

    it "inherits from ApplicationJob" do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end

  describe "integration with ActiveJob" do
    it "can be enqueued" do
      expect do
        described_class.perform_later
      end.not_to raise_error
    end

    it "can be enqueued with slack notification" do
      expect do
        described_class.perform_later(send_slack_notification: true)
      end.not_to raise_error
    end
  end
end
