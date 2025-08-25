# frozen_string_literal: true

namespace :high_frequency do
  desc "Validate high-frequency job scheduling and performance"
  task validate: :environment do
    puts "\n🔍 High-Frequency System Validation"
    puts "=" * 50

    validator = HighFrequencyValidator.new
    
    puts "\n📊 Running validation tests..."
    results = validator.run_validation_suite
    
    puts "\n📋 Validation Results:"
    puts "=" * 30
    
    results.each do |category, tests|
      puts "\n#{category.to_s.humanize}:"
      tests.each do |test_name, result|
        status = result[:passed] ? "✅ PASS" : "❌ FAIL"
        puts "  #{status} #{test_name}"
        puts "    #{result[:message]}" if result[:message]
        puts "    Value: #{result[:value]}" if result[:value]
      end
    end

    # Summary
    total_tests = results.values.map(&:size).sum
    passed_tests = results.values.map { |tests| tests.values.count { |r| r[:passed] } }.sum
    pass_rate = (passed_tests.to_f / total_tests * 100).round(2)

    puts "\n📈 Summary:"
    puts "  Total Tests: #{total_tests}"
    puts "  Passed: #{passed_tests}"
    puts "  Failed: #{total_tests - passed_tests}"
    puts "  Pass Rate: #{pass_rate}%"

    if pass_rate >= 90
      puts "\n🎉 High-frequency system validation PASSED!"
    elsif pass_rate >= 75
      puts "\n⚠️  High-frequency system validation passed with warnings"
    else
      puts "\n🚨 High-frequency system validation FAILED!"
      exit 1
    end
  end

  desc "Test high-frequency job execution performance"
  task performance_test: :environment do
    puts "\n⚡ High-Frequency Performance Test"
    puts "=" * 40

    tester = HighFrequencyPerformanceTester.new
    results = tester.run_performance_tests

    puts "\n📊 Performance Test Results:"
    results.each do |job_class, metrics|
      puts "\n#{job_class}:"
      puts "  Execution Time: #{metrics[:execution_time_ms]}ms"
      puts "  Memory Usage: #{metrics[:memory_usage_mb]}MB"
      puts "  Success Rate: #{metrics[:success_rate]}%"
      puts "  Status: #{metrics[:status]}"
    end
  end

  desc "Stress test high-frequency operations"
  task stress_test: :environment do
    puts "\n🔥 High-Frequency Stress Test"
    puts "=" * 35

    puts "⚠️  Warning: This will run high-frequency jobs rapidly for testing."
    puts "Only run this in development/test environments!"
    
    print "Continue? (y/N): "
    input = STDIN.gets.chomp.downcase
    
    unless input == 'y' || input == 'yes'
      puts "Stress test cancelled."
      exit 0
    end

    stress_tester = HighFrequencyStressTester.new
    stress_tester.run_stress_test
  end

  desc "Monitor high-frequency system metrics"
  task monitor: :environment do
    puts "\n📊 High-Frequency System Monitor"
    puts "=" * 40

    monitor = HighFrequencyPerformanceMonitor.new
    
    puts "Collecting system metrics..."
    metrics = monitor.collect_system_metrics
    
    puts "\n🖥️  System Metrics:"
    puts "  Memory Usage: #{metrics[:system][:memory_usage_mb]}MB (#{metrics[:system][:memory_usage_percent]}%)"
    puts "  CPU Usage: #{metrics[:system][:cpu_usage_percent]}%"
    puts "  Load Average: #{metrics[:system][:load_average].join(', ')}"
    
    puts "\n💾 Database Metrics:"
    puts "  Active Connections: #{metrics[:database][:active_connections]}"
    puts "  Avg Query Time: #{metrics[:database][:avg_query_time_ms]}ms"
    
    puts "\n⚙️  Job Queue Metrics:"
    puts "  Queue Depth: #{metrics[:job_queue][:queue_depth]}"
    puts "  HF Queue Depth: #{metrics[:job_queue][:high_frequency_queue_depth]}"
    puts "  Failed Jobs (1h): #{metrics[:job_queue][:failed_jobs_last_hour]}"
    
    puts "\n📈 Trading Metrics:"
    puts "  Open Positions: #{metrics[:trading][:open_positions_count]}"
    puts "  Day Trading Positions: #{metrics[:trading][:day_trading_positions_count]}"
    puts "  Stale Price Data: #{metrics[:trading][:stale_price_data_count]}"
    
    # Check for alerts
    alerts = monitor.check_performance_alerts(metrics)
    if alerts.any?
      puts "\n🚨 Alerts:"
      alerts.each do |alert|
        puts "  #{alert[:severity].upcase}: #{alert[:message]}"
      end
    else
      puts "\n✅ No performance alerts"
    end
  end
end

# Validation classes
class HighFrequencyValidator
  def initialize
    @logger = Rails.logger
  end

  def run_validation_suite
    {
      configuration: validate_configuration,
      database: validate_database,
      jobs: validate_jobs,
      performance: validate_performance
    }
  end

  private

  def validate_configuration
    tests = {}

    # Check GoodJob configuration
    tests["GoodJob cron enabled"] = {
      passed: Rails.application.config.good_job.enable_cron == true,
      message: "Cron scheduling must be enabled"
    }

    # Check high-frequency queue
    queues = Rails.application.config.good_job.queues
    tests["High-frequency queue configured"] = {
      passed: queues.include?("high_frequency"),
      message: "high_frequency queue must be configured",
      value: queues
    }

    # Check poll interval
    poll_interval = Rails.application.config.good_job.poll_interval
    tests["Optimized poll interval"] = {
      passed: poll_interval <= 2,
      message: "Poll interval should be <= 2 seconds for high-frequency",
      value: "#{poll_interval}s"
    }

    # Check max threads
    max_threads = Rails.application.config.good_job.max_threads
    tests["Adequate thread pool"] = {
      passed: max_threads >= 8,
      message: "Should have >= 8 threads for high-frequency operations",
      value: max_threads
    }

    tests
  end

  def validate_database
    tests = {}

    # Check database indexes
    connection = ActiveRecord::Base.connection
    
    # Check for high-frequency indexes
    hf_indexes = [
      'idx_positions_status_day_trading',
      'idx_candles_hf_timeframes', 
      'idx_trading_pairs_enabled_price_updated',
      'idx_good_jobs_queue_priority_scheduled'
    ]

    hf_indexes.each do |index_name|
      index_exists = connection.indexes('positions').any? { |i| i.name == index_name } ||
                    connection.indexes('candles').any? { |i| i.name == index_name } ||
                    connection.indexes('trading_pairs').any? { |i| i.name == index_name } ||
                    connection.indexes('good_jobs').any? { |i| i.name == index_name }
      
      tests["Index #{index_name}"] = {
        passed: index_exists,
        message: "Required for high-frequency queries"
      }
    end

    # Check for required columns
    required_columns = {
      'trading_pairs' => ['last_price', 'last_price_updated_at'],
      'positions' => ['unrealized_pnl', 'current_price']
    }

    required_columns.each do |table, columns|
      columns.each do |column|
        column_exists = connection.column_exists?(table, column)
        tests["Column #{table}.#{column}"] = {
          passed: column_exists,
          message: "Required for high-frequency tracking"
        }
      end
    end

    tests
  end

  def validate_jobs
    tests = {}

    # Check high-frequency job classes exist
    hf_job_classes = [
      'HighFrequencyMarketDataJob',
      'HighFrequency1mCandleJob',
      'HighFrequencyPnLTrackingJob',
      'HighFrequencyPositionMonitorJob',
      'HighFrequencySignalGenerationJob'
    ]

    hf_job_classes.each do |job_class|
      begin
        klass = job_class.constantize
        tests["Job class #{job_class}"] = {
          passed: klass.ancestors.include?(ApplicationJob),
          message: "Job class must exist and inherit from ApplicationJob"
        }
      rescue NameError
        tests["Job class #{job_class}"] = {
          passed: false,
          message: "Job class does not exist"
        }
      end
    end

    # Check cron configuration
    cron_config = Rails.application.config.good_job.cron || {}
    hf_cron_jobs = %w[hf_market_data hf_candles_1m hf_pnl_tracking hf_position_monitor hf_signals_5m]

    hf_cron_jobs.each do |cron_key|
      tests["Cron job #{cron_key}"] = {
        passed: cron_config.key?(cron_key.to_sym),
        message: "Must be configured in cron schedule"
      }
    end

    tests
  end

  def validate_performance
    tests = {}

    # Check Rails cache
    tests["Rails cache available"] = {
      passed: Rails.cache.respond_to?(:write) && Rails.cache.respond_to?(:read),
      message: "Rails cache required for high-frequency operations"
    }

    # Test cache performance
    start_time = Time.current
    Rails.cache.write('hf_test_key', 'test_value')
    cached_value = Rails.cache.read('hf_test_key')
    cache_time = (Time.current - start_time) * 1000

    tests["Cache performance"] = {
      passed: cache_time < 10 && cached_value == 'test_value',
      message: "Cache operations should complete in < 10ms",
      value: "#{cache_time.round(2)}ms"
    }

    # Test database query performance
    start_time = Time.current
    Position.open.limit(10).to_a
    query_time = (Time.current - start_time) * 1000

    tests["Database query performance"] = {
      passed: query_time < 50,
      message: "Simple queries should complete in < 50ms",
      value: "#{query_time.round(2)}ms"
    }

    tests
  end
end

class HighFrequencyPerformanceTester
  def initialize
    @logger = Rails.logger
  end

  def run_performance_tests
    results = {}

    # Test each high-frequency job
    hf_jobs = [
      HighFrequencyMarketDataJob,
      HighFrequency1mCandleJob,
      HighFrequencyPnLTrackingJob,
      HighFrequencyPositionMonitorJob,
      HighFrequencySignalGenerationJob
    ]

    hf_jobs.each do |job_class|
      results[job_class.name] = test_job_performance(job_class)
    end

    results
  end

  private

  def test_job_performance(job_class)
    puts "Testing #{job_class.name}..."
    
    start_time = Time.current
    memory_before = get_memory_usage

    begin
      # Create and perform job
      job = job_class.new
      job.perform
      
      execution_time = (Time.current - start_time) * 1000
      memory_after = get_memory_usage
      memory_usage = memory_after - memory_before

      {
        execution_time_ms: execution_time.round(2),
        memory_usage_mb: memory_usage.round(2),
        success_rate: 100,
        status: execution_time < 5000 ? 'PASS' : 'SLOW'
      }
    rescue => e
      execution_time = (Time.current - start_time) * 1000
      
      {
        execution_time_ms: execution_time.round(2),
        memory_usage_mb: 0,
        success_rate: 0,
        status: 'FAIL',
        error: e.message
      }
    end
  end

  def get_memory_usage
    return 0 unless defined?(GC)
    
    gc_stats = GC.stat
    (gc_stats[:heap_allocated_pages] * gc_stats[:heap_page_size]) / (1024 * 1024)
  rescue
    0
  end
end

class HighFrequencyStressTester
  def run_stress_test
    puts "\nStarting stress test with rapid job execution..."
    
    # Run multiple high-frequency jobs rapidly
    job_classes = [
      HighFrequencyMarketDataJob,
      HighFrequencyPnLTrackingJob,
      HighFrequencyPositionMonitorJob
    ]

    threads = []
    start_time = Time.current

    # Run 10 iterations of each job
    10.times do |i|
      job_classes.each do |job_class|
        threads << Thread.new do
          begin
            job_class.perform_now
            puts "  ✅ #{job_class.name} iteration #{i + 1} completed"
          rescue => e
            puts "  ❌ #{job_class.name} iteration #{i + 1} failed: #{e.message}"
          end
        end
      end
    end

    # Wait for all threads to complete
    threads.each(&:join)

    total_time = Time.current - start_time
    puts "\n🏁 Stress test completed in #{total_time.round(2)} seconds"
    puts "📊 Average time per job: #{(total_time / (job_classes.size * 10)).round(2)} seconds"
  end
end