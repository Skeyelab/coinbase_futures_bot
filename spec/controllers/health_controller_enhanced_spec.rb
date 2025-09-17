# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HealthController, type: :controller do
  describe 'GET #show' do
    let!(:day_position) { create(:position, day_trading: true, status: 'OPEN') }
    let!(:swing_position) { create(:position, day_trading: false, status: 'OPEN') }

    before do
      allow(ActiveRecord::Base.connection).to receive(:execute).with('SELECT 1').and_return(true)
      allow(GoodJob::Job).to receive(:where).and_return(double(count: 0))
    end

    it 'includes position type breakdown in response' do
      get :show

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)

      expect(json_response['positions']).to include(
        'day_trading' => 1,
        'swing_trading' => 1,
        'total' => 2
      )
    end

    it 'includes cached health check data when available' do
      cached_health = {
        timestamp: 5.minutes.ago,
        data: {
          overall_health: 'healthy',
          margin_health: { overall: { available_margin: '1000.00' } }
        }
      }
      allow(Rails.cache).to receive(:read).with('last_health_check').and_return(cached_health)

      get :show

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)

      expect(json_response).to include('detailed_health')
      expect(json_response['detailed_health']).to include('margin_health')
      expect(json_response['last_health_check']).to be_present
    end

    it 'handles position counting errors gracefully' do
      allow(Position).to receive(:open).and_raise(StandardError.new('DB Error'))

      get :show

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)

      expect(json_response['positions']).to eq({
        'day_trading' => 0,
        'swing_trading' => 0,
        'total' => 0
      })
    end

    context 'when database connection fails' do
      before do
        allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(StandardError.new('Connection failed'))
      end

      it 'returns service unavailable status' do
        get :show

        expect(response).to have_http_status(:service_unavailable)
        json_response = JSON.parse(response.body)

        expect(json_response['status']).to eq('unhealthy')
        expect(json_response['database']['connection_ok']).to be false
      end

      it 'still includes position data when database connection fails' do
        # Position counting should still work even if the health check connection fails
        get :show

        json_response = JSON.parse(response.body)
        expect(json_response).to include('positions')
      end
    end

    context 'with GoodJob stats' do
      let(:good_job_stats) do
        {
          queued: 5,
          running: 2,
          failed: 1
        }
      end

      before do
        allow(GoodJob::Job).to receive(:where).with(finished_at: nil).and_return(double(count: 5))
        allow(GoodJob::Job).to receive(:where).and_return(double(where: double(count: 2)))
        allow(GoodJob::Job).to receive(:where).with(hash_not_including(finished_at: nil)).and_return(double(where: double(count: 1)))
      end

      it 'includes job queue statistics' do
        get :show

        expect(response).to have_http_status(:ok)
        json_response = JSON.parse(response.body)

        expect(json_response['good_job']).to include(
          'queued',
          'running',
          'failed'
        )
      end
    end

    context 'when GoodJob stats fail' do
      before do
        allow(GoodJob::Job).to receive(:where).and_raise(StandardError.new('GoodJob error'))
      end

      it 'handles GoodJob errors gracefully' do
        get :show

        expect(response).to have_http_status(:ok)
        json_response = JSON.parse(response.body)

        expect(json_response['good_job']).to be_nil
      end
    end

    it 'includes all required health data fields' do
      get :show

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)

      expect(json_response).to include(
        'status',
        'timestamp',
        'database',
        'positions',
        'environment'
      )

      expect(json_response['database']).to include(
        'connection_ok',
        'pool'
      )

      expect(json_response['database']['pool']).to include(
        'size',
        'connections',
        'in_use',
        'available',
        'waiting'
      )
    end

    it 'formats timestamp correctly' do
      get :show

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)

      expect(json_response['timestamp']).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    it 'includes environment information' do
      get :show

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)

      expect(json_response['environment']).to eq(Rails.env)
    end
  end

  describe 'Sentry integration' do
    before do
      allow(ActiveRecord::Base.connection).to receive(:execute).with('SELECT 1').and_return(true)
      allow(GoodJob::Job).to receive(:where).and_return(double(count: 0))
    end

    it 'adds breadcrumb for health check requests' do
      expect(SentryHelper).to receive(:add_breadcrumb).with(
        message: 'Health check requested',
        category: 'health_check',
        level: 'info',
        data: { controller: 'health', action: 'show' }
      )

      get :show
    end

    context 'when database connectivity fails' do
      before do
        allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(StandardError.new('DB Error'))
      end

      it 'captures database connectivity errors in Sentry' do
        expect(Sentry).to receive(:with_scope) do |&block|
          scope = instance_double('Sentry::Scope')
          allow(scope).to receive(:set_tag)
          allow(scope).to receive(:set_context)
          expect(scope).to receive(:set_tag).with('health_check_type', 'database')
          expect(scope).to receive(:set_tag).with('error_type', 'database_connectivity_error')
          
          block.call(scope)
        end

        expect(Sentry).to receive(:capture_exception)

        get :show
      end
    end

    context 'when GoodJob stats have high failure count' do
      before do
        allow(GoodJob::Job).to receive(:where).with(finished_at: nil).and_return(double(count: 5))
        allow(GoodJob::Job).to receive(:where).and_return(double(where: double(count: 2)))
        allow(GoodJob::Job).to receive(:where).with(hash_not_including(finished_at: nil)).and_return(double(where: double(count: 15))) # High failure count
      end

      it 'captures high failed job count warnings in Sentry' do
        expect(Sentry).to receive(:with_scope) do |&block|
          scope = instance_double('Sentry::Scope')
          allow(scope).to receive(:set_tag)
          allow(scope).to receive(:set_context)
          expect(scope).to receive(:set_tag).with('health_check_type', 'job_queue')
          expect(scope).to receive(:set_tag).with('error_type', 'high_failed_job_count')
          
          block.call(scope)
        end

        expect(Sentry).to receive(:capture_message).with(
          'High number of failed jobs detected',
          level: 'warning'
        )

        get :show
      end
    end
  end
end