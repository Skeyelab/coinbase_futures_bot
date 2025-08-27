# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HealthCheckJob, type: :job do
  let(:job) { described_class.new }

  before do
    # Mock external dependencies
    allow(ActiveRecord::Base.connection).to receive(:active?).and_return(true)
    allow(Coinbase::Client).to receive(:new).and_return(double(test_auth: {
      advanced_trade: { ok: true },
      exchange: { ok: true }
    }))
    allow(GoodJob::Job).to receive_message_chain(:where, :exists?).and_return(true)
    allow(GoodJob::CronEntry).to receive(:all).and_return([
      double(job_class: 'GenerateSignalsJob'),
      double(job_class: 'DayTradingPositionManagementJob')
    ])
    allow(Position).to receive_message_chain(:open, :day_trading, :count).and_return(2)
    allow(Rails.cache).to receive(:fetch).with('trading_active', expires_in: 1.hour).and_return(true)
    allow(Rails.cache).to receive(:write)
  end

  describe '#perform' do
    context 'with healthy system' do
      it 'completes successfully and returns health data' do
        result = job.perform
        
        expect(result).to be_a(Hash)
        expect(result[:overall_health]).to eq('healthy')
        expect(result[:database]).to be true
        expect(result[:coinbase_api]).to be true
        expect(result[:background_jobs]).to be true
        expect(result[:trading_active]).to be true
        expect(result[:open_positions]).to eq(2)
      end

      it 'caches health check results' do
        expect(Rails.cache).to receive(:write) do |key, value, options|
          expect(key).to eq('last_health_check')
          expect(value[:data]).to be_a(Hash)
          expect(options[:expires_in]).to eq(1.hour)
        end
        
        job.perform
      end

      it 'does not send Slack notification for healthy system' do
        expect(SlackNotificationService).not_to receive(:health_check)
        
        job.perform(send_slack_notification: false)
      end
    end

    context 'with send_slack_notification: true' do
      it 'sends Slack notification regardless of health status' do
        expect(SlackNotificationService).to receive(:health_check)
        
        job.perform(send_slack_notification: true)
      end
    end

    context 'with unhealthy system' do
      before do
        allow(ActiveRecord::Base.connection).to receive(:active?).and_return(false)
      end

      it 'sends Slack notification for unhealthy system' do
        expect(SlackNotificationService).to receive(:health_check) do |health_data|
          expect(health_data[:overall_health]).to eq('unhealthy')
          expect(health_data[:database]).to be false
        end
        
        job.perform
      end

      it 'returns unhealthy status' do
        result = job.perform
        
        expect(result[:overall_health]).to eq('unhealthy')
        expect(result[:database]).to be false
      end
    end

    context 'with warning conditions' do
      before do
        # Database OK, but Coinbase API down
        allow(Coinbase::Client).to receive(:new).and_raise(StandardError.new('API error'))
      end

      it 'returns warning status' do
        result = job.perform
        
        expect(result[:overall_health]).to eq('warning')
        expect(result[:database]).to be true
        expect(result[:coinbase_api]).to be false
      end
    end

    context 'when job fails' do
      let(:error) { StandardError.new('Test error') }

      before do
        allow(job).to receive(:gather_health_data).and_raise(error)
      end

      it 'sends error alert to Slack' do
        expect(SlackNotificationService).to receive(:alert) do |level, title, details|
          expect(level).to eq('error')
          expect(title).to eq('Health Check Failed')
          expect(details).to include('Test error')
        end
        
        expect { job.perform }.to raise_error(error)
      end
    end
  end

  describe 'private methods' do
    describe '#check_database_health' do
      it 'returns true when database is connected' do
        allow(ActiveRecord::Base.connection).to receive(:active?).and_return(true)
        
        result = job.send(:check_database_health)
        expect(result).to be true
      end

      it 'returns false when database connection fails' do
        allow(ActiveRecord::Base.connection).to receive(:active?).and_raise(StandardError)
        
        result = job.send(:check_database_health)
        expect(result).to be false
      end
    end

    describe '#check_coinbase_api_health' do
      it 'returns true when both APIs are healthy' do
        client = double(test_auth: {
          advanced_trade: { ok: true },
          exchange: { ok: true }
        })
        allow(Coinbase::Client).to receive(:new).and_return(client)
        
        result = job.send(:check_coinbase_api_health)
        expect(result).to be true
      end

      it 'returns false when advanced trade API fails' do
        client = double(test_auth: {
          advanced_trade: { ok: false },
          exchange: { ok: true }
        })
        allow(Coinbase::Client).to receive(:new).and_return(client)
        
        result = job.send(:check_coinbase_api_health)
        expect(result).to be false
      end

      it 'returns false when API call raises exception' do
        allow(Coinbase::Client).to receive(:new).and_raise(StandardError.new('API error'))
        
        result = job.send(:check_coinbase_api_health)
        expect(result).to be false
      end
    end

    describe '#check_background_jobs_health' do
      it 'returns true when jobs are running and critical jobs are scheduled' do
        allow(GoodJob::Job).to receive_message_chain(:where, :exists?).and_return(true)
        allow(GoodJob::CronEntry).to receive(:all).and_return([
          double(job_class: 'GenerateSignalsJob'),
          double(job_class: 'DayTradingPositionManagementJob'),
          double(job_class: 'FetchCandlesJob')
        ])
        
        result = job.send(:check_background_jobs_health)
        expect(result).to be true
      end

      it 'returns false when no recent jobs found' do
        allow(GoodJob::Job).to receive_message_chain(:where, :exists?).and_return(false)
        
        result = job.send(:check_background_jobs_health)
        expect(result).to be false
      end

      it 'returns false when critical jobs are not scheduled' do
        allow(GoodJob::CronEntry).to receive(:all).and_return([])
        
        result = job.send(:check_background_jobs_health)
        expect(result).to be false
      end
    end

    describe '#get_memory_usage' do
      context 'on Linux system' do
        let(:meminfo_content) do
          <<~MEMINFO
            MemTotal:       8000000 kB
            MemFree:        2000000 kB
            MemAvailable:   3000000 kB
            Buffers:         100000 kB
          MEMINFO
        end

        before do
          allow(File).to receive(:readable?).with('/proc/meminfo').and_return(true)
          allow(File).to receive(:read).with('/proc/meminfo').and_return(meminfo_content)
        end

        it 'returns formatted memory usage' do
          result = job.send(:get_memory_usage)
          expect(result).to include('% used')
          expect(result).to include('MB')
        end
      end

      context 'on non-Linux system' do
        before do
          allow(File).to receive(:readable?).with('/proc/meminfo').and_return(false)
        end

        it 'returns not available message' do
          result = job.send(:get_memory_usage)
          expect(result).to eq('Memory info not available')
        end
      end

      context 'when file reading fails' do
        before do
          allow(File).to receive(:readable?).with('/proc/meminfo').and_return(true)
          allow(File).to receive(:read).with('/proc/meminfo').and_raise(StandardError)
        end

        it 'returns error message' do
          result = job.send(:get_memory_usage)
          expect(result).to eq('Error reading memory info')
        end
      end
    end

    describe '#calculate_overall_health' do
      it 'returns healthy when all critical and important checks pass' do
        checks = {
          database: true,
          background_jobs: true,
          coinbase_api: true
        }
        
        result = job.send(:calculate_overall_health, checks)
        expect(result).to eq('healthy')
      end

      it 'returns warning when critical checks pass but important checks fail' do
        checks = {
          database: true,
          background_jobs: true,
          coinbase_api: false
        }
        
        result = job.send(:calculate_overall_health, checks)
        expect(result).to eq('warning')
      end

      it 'returns unhealthy when critical checks fail' do
        checks = {
          database: false,
          background_jobs: true,
          coinbase_api: true
        }
        
        result = job.send(:calculate_overall_health, checks)
        expect(result).to eq('unhealthy')
      end
    end
  end
end