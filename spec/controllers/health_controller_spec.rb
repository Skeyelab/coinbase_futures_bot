# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthController, type: :controller do
  before do
    # Mock SentryHelper to avoid external calls
    allow(SentryHelper).to receive(:add_breadcrumb)

    # Mock Sentry to avoid external calls - simplified approach
    allow(Sentry).to receive(:with_scope).and_yield(double(
      set_tag: true,
      set_context: true
    ))
    allow(Sentry).to receive(:capture_exception)
    allow(Sentry).to receive(:capture_message)

    # Mock Rails logger to avoid noise in test output
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:warn)

    # Mock Time.current for consistent test results
    allow(Time).to receive(:current).and_return(Time.utc(2024, 1, 1, 12, 0, 0))
  end

  describe "GET #show" do
    context "when system is healthy" do
      it "returns healthy status with 200 OK" do
        get :show

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("application/json")
      end

      it "includes Sentry breadcrumb for health check" do
        get :show

        expect(SentryHelper).to have_received(:add_breadcrumb).with(
          message: "Health check requested",
          category: "health_check",
          level: "info",
          data: {controller: "health", action: "show"}
        )
      end

      it "returns comprehensive health data with real database stats" do
        get :show

        json_response = JSON.parse(response.body)

        expect(json_response["status"]).to eq("healthy")
        expect(json_response["timestamp"]).to eq("2024-01-01T12:00:00Z")
        expect(json_response["environment"]).to eq("test")

        # Database section - these should be real values from the test database
        expect(json_response["database"]["connection_ok"]).to be true
        expect(json_response["database"]["pool"]).to be_present

        # Verify pool stats are real integers from the actual connection pool
        pool_stats = json_response["database"]["pool"]
        expect(pool_stats["size"]).to be_a(Integer)
        expect(pool_stats["size"]).to be > 0
        expect(pool_stats["connections"]).to be_a(Integer)
        expect(pool_stats["connections"]).to be >= 0
        expect(pool_stats["in_use"]).to be_a(Integer)
        expect(pool_stats["in_use"]).to be >= 0
        expect(pool_stats["available"]).to be_a(Integer)
        expect(pool_stats["available"]).to be >= 0
        expect(pool_stats["waiting"]).to be_a(Integer)
        expect(pool_stats["waiting"]).to be >= 0

        # Verify pool stats calculation logic
        expect(pool_stats["available"]).to eq(pool_stats["size"] - pool_stats["in_use"])

        # GoodJob section - these should be real counts from the test database
        expect(json_response["good_job"]).to be_present
        expect(json_response["good_job"]["queued"]).to be_a(Integer)
        expect(json_response["good_job"]["queued"]).to be >= 0
        expect(json_response["good_job"]["running"]).to be_a(Integer)
        expect(json_response["good_job"]["running"]).to be >= 0
        expect(json_response["good_job"]["failed"]).to be_a(Integer)
        expect(json_response["good_job"]["failed"]).to be >= 0
      end

      it "includes all required health check fields" do
        get :show

        json_response = JSON.parse(response.body)

        # Required top-level fields
        expect(json_response).to have_key("status")
        expect(json_response).to have_key("timestamp")
        expect(json_response).to have_key("environment")
        expect(json_response).to have_key("database")
        expect(json_response).to have_key("good_job")

        # Required database fields
        expect(json_response["database"]).to have_key("connection_ok")
        expect(json_response["database"]).to have_key("pool")

        # Required pool fields
        expect(json_response["database"]["pool"]).to have_key("size")
        expect(json_response["database"]["pool"]).to have_key("connections")
        expect(json_response["database"]["pool"]).to have_key("in_use")
        expect(json_response["database"]["pool"]).to have_key("available")
        expect(json_response["database"]["pool"]).to have_key("waiting")

        # Required GoodJob fields
        expect(json_response["good_job"]).to have_key("queued")
        expect(json_response["good_job"]).to have_key("running")
        expect(json_response["good_job"]).to have_key("failed")
      end
    end

    context "when database connection fails" do
      before do
        # Mock database connection failure by stubbing the execute method
        allow_any_instance_of(ActiveRecord::ConnectionAdapters::AbstractAdapter).to receive(:execute).with("SELECT 1").and_raise(ActiveRecord::ConnectionNotEstablished.new("Connection failed"))
      end

      it "returns unhealthy status with 503 Service Unavailable" do
        get :show

        expect(response).to have_http_status(:service_unavailable)
      end

      it "logs database health check failure" do
        get :show

        expect(Rails.logger).to have_received(:error).with("Database health check failed: Connection failed")
      end

      it "captures Sentry exception with database context" do
        get :show

        expect(Sentry).to have_received(:with_scope)
        expect(Sentry).to have_received(:capture_exception).with(instance_of(ActiveRecord::ConnectionNotEstablished))
      end

      it "returns health data with database failure indicated" do
        get :show

        json_response = JSON.parse(response.body)
        expect(json_response["status"]).to eq("unhealthy")
        expect(json_response["database"]["connection_ok"]).to be false
        expect(json_response["database"]["pool"]).to be_present
      end
    end

    context "when GoodJob stats are unavailable" do
      before do
        # Mock GoodJob failure by stubbing the where method
        allow(GoodJob::Job).to receive(:where).and_raise(StandardError.new("GoodJob unavailable"))
      end

      it "handles GoodJob unavailability gracefully" do
        get :show

        expect(response).to have_http_status(:ok)
        expect(Rails.logger).to have_received(:warn).with("GoodJob stats unavailable: GoodJob unavailable")
      end

      it "captures Sentry exception for GoodJob failures" do
        get :show

        expect(Sentry).to have_received(:with_scope)
        expect(Sentry).to have_received(:capture_exception).with(instance_of(StandardError))
      end

      it "returns nil for GoodJob stats in response" do
        get :show

        json_response = JSON.parse(response.body)
        expect(json_response["good_job"]).to be_nil
      end
    end

    context "when GoodJob has high failed job count" do
      before do
        # Create failed GoodJob records directly
        15.times do
          GoodJob::Job.create!(
            queue_name: "default",
            priority: 0,
            serialized_params: {},
            error: "Test error",
            created_at: Time.current,
            updated_at: Time.current
          )
        end
      end

      it "triggers Sentry warning when failed jobs exceed threshold" do
        get :show

        expect(Sentry).to have_received(:with_scope)
        expect(Sentry).to have_received(:capture_message).with("High number of failed jobs detected", level: "warning")
      end

      it "still returns successful response" do
        get :show

        expect(response).to have_http_status(:ok)
        json_response = JSON.parse(response.body)
        expect(json_response["status"]).to eq("healthy")
        expect(json_response["good_job"]["failed"]).to eq(15)
      end
    end

    context "edge cases" do
      it "handles zero job counts correctly" do
        get :show

        json_response = JSON.parse(response.body)
        expect(json_response["good_job"]["queued"]).to eq(0)
        expect(json_response["good_job"]["running"]).to eq(0)
        expect(json_response["good_job"]["failed"]).to eq(0)
      end
    end
  end
end
