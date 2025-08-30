# frozen_string_literal: true

namespace :sentry do
  desc "Test Sentry error tracking and monitoring"
  task test: :environment do
    puts "🔍 Testing Sentry integration..."

    unless ENV["SENTRY_DSN"].present?
      puts "❌ SENTRY_DSN not configured. Set SENTRY_DSN environment variable."
      exit 1
    end

    # Test basic error capture
    begin
      puts "📤 Testing basic error capture..."
      Sentry.capture_message("Sentry test message from rake task", level: "info")
      puts "✅ Basic message sent"
    rescue => e
      puts "❌ Failed to send basic message: #{e.message}"
    end

    # Test exception capture
    begin
      puts "📤 Testing exception capture..."
      begin
        raise StandardError, "Test exception for Sentry verification"
      rescue => e
        Sentry.capture_exception(e)
        puts "✅ Exception captured"
      end
    rescue => e
      puts "❌ Failed to capture exception: #{e.message}"
    end

    # Test breadcrumbs
    begin
      puts "📤 Testing breadcrumbs..."
      SentryHelper.add_breadcrumb(
        message: "Test breadcrumb from rake task",
        category: "test",
        level: "info",
        data: {test: true, timestamp: Time.current.utc.iso8601}
      )
      puts "✅ Breadcrumb added"
    rescue => e
      puts "❌ Failed to add breadcrumb: #{e.message}"
    end

    # Test custom tags and context
    begin
      puts "📤 Testing custom tags and context..."
      Sentry.with_scope do |scope|
        scope.set_tag("test_type", "rake_task")
        scope.set_tag("component", "sentry_verification")
        scope.set_context("test_context", {
          task: "sentry:test",
          environment: Rails.env,
          timestamp: Time.current.utc.iso8601
        })

        Sentry.capture_message("Sentry verification test with custom context", level: "info")
      end
      puts "✅ Custom tags and context sent"
    rescue => e
      puts "❌ Failed to send with custom context: #{e.message}"
    end

    # Test performance monitoring if enabled
    if ENV["SENTRY_TRACES_SAMPLE_RATE"].to_f > 0
      begin
        puts "📤 Testing performance monitoring..."
        Sentry.start_transaction(name: "sentry:test", op: "task") do |transaction|
          # Simulate some work
          sleep(0.1)
          transaction.set_data("test_data", {duration: 0.1})
        end
        puts "✅ Performance transaction completed"
      rescue => e
        puts "❌ Failed to create performance transaction: #{e.message}"
      end
    else
      puts "⚠️  Performance monitoring disabled (SENTRY_TRACES_SAMPLE_RATE=0)"
    end

    puts "🎉 Sentry integration test completed!"
    puts ""
    puts "Check your Sentry dashboard for the test events:"
    puts "- Test message"
    puts "- Test exception"
    puts "- Test breadcrumb"
    puts "- Custom context message"
    puts "- Performance transaction (if enabled)"
  end

  desc "Test job error tracking"
  task test_job: :environment do
    puts "🔍 Testing job error tracking..."

    # Test successful job execution tracking
    puts "📤 Testing successful job execution..."
    TestJob.perform_now
    puts "✅ TestJob executed successfully"

    # Test job error tracking
    puts "📤 Testing job error tracking..."
    begin
      # Create a job that will fail
      job = Class.new(ApplicationJob) do
        def perform
          raise StandardError, "Test job error for Sentry verification"
        end
      end

      job.perform_now
    rescue => e
      puts "✅ Job error captured (expected): #{e.message}"
    end

    puts "🎉 Job error tracking test completed!"
  end

  desc "Test service error tracking"
  task test_service: :environment do
    puts "🔍 Testing service error tracking..."

    # Test Coinbase API error tracking
    puts "📤 Testing Coinbase API error tracking..."
    begin
      client = Coinbase::AdvancedTradeClient.new
      # This will fail if not authenticated, which is expected
      client.test_auth
      puts "✅ Coinbase API test completed"
    rescue => e
      puts "✅ Coinbase API error captured (expected): #{e.message}"
    end

    # Test Slack service error tracking
    puts "📤 Testing Slack service error tracking..."
    begin
      # This will fail if Slack is not configured
      SlackNotificationService.alert("info", "Test Alert", "Sentry test message")
      puts "✅ Slack test completed"
    rescue => e
      puts "✅ Slack error captured (expected): #{e.message}"
    end

    puts "🎉 Service error tracking test completed!"
  end

  desc "Test performance monitoring"
  task test_performance: :environment do
    puts "🔍 Testing performance monitoring..."

    # Test database performance monitoring
    puts "📤 Testing database performance monitoring..."
    start_time = Time.current

    # Execute a few database queries
    TradingPair.count
    Position.count
    SignalAlert.limit(10).to_a

    duration = (Time.current - start_time) * 1000
    puts "✅ Database queries executed (#{duration.round(2)}ms)"

    # Test memory monitoring
    puts "📤 Testing memory monitoring..."
    SentryPerformanceService.track_memory_usage
    puts "✅ Memory usage tracked"

    # Test job queue monitoring
    puts "📤 Testing job queue monitoring..."
    SentryPerformanceService.track_job_queue_performance
    puts "✅ Job queue performance tracked"

    puts "🎉 Performance monitoring test completed!"
  end

  desc "Show Sentry configuration"
  task config: :environment do
    puts "🔧 Sentry Configuration:"
    puts ""
    puts "DSN: #{ENV["SENTRY_DSN"].present? ? "✅ Configured" : "❌ Not configured"}"
    puts "Environment: #{Rails.env}"
    puts "Traces Sample Rate: #{ENV["SENTRY_TRACES_SAMPLE_RATE"] || "default"}"
    puts "Profiles Sample Rate: #{ENV["SENTRY_PROFILES_SAMPLE_RATE"] || "default"}"
    puts "Release: #{ENV["APP_VERSION"] || "unknown"}"
    puts ""
    puts "Trading Context:"
    puts "Paper Trading Mode: #{(ENV["PAPER_TRADING_MODE"] == "true") ? "✅ Enabled" : "❌ Disabled"}"
    puts "Sentiment Enabled: #{(ENV["SENTIMENT_ENABLE"] == "true") ? "✅ Enabled" : "❌ Disabled"}"
    puts "Coinbase Credentials: #{File.exist?(Rails.root.join("cdp_api_key.json")) ? "✅ Present" : "❌ Missing"}"
    puts ""
    puts "Performance Thresholds:"
    puts "Slow Query: #{ENV["SENTRY_SLOW_QUERY_THRESHOLD"] || 1000}ms"
    puts "Slow API: #{ENV["SENTRY_SLOW_API_THRESHOLD"] || 5000}ms"
    puts "Slow Trading: #{ENV["SENTRY_SLOW_TRADING_THRESHOLD"] || 10000}ms"
    puts "High Memory: #{ENV["SENTRY_HIGH_MEMORY_THRESHOLD"] || 1000}MB"
  end

  desc "Run comprehensive Sentry test suite"
  task test_all: [:test, :test_job, :test_service, :test_performance] do
    puts ""
    puts "🎉 All Sentry tests completed!"
    puts "Check your Sentry dashboard for all test events and performance data."
  end
end
