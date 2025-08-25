# frozen_string_literal: true

class HighFrequencyPerformanceMonitor
  attr_reader :logger

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  # Monitor overall system performance metrics
  def collect_system_metrics
    start_time = Time.current

    metrics = {
      timestamp: Time.current,
      system: collect_system_resource_metrics,
      database: collect_database_metrics,
      job_queue: collect_job_queue_metrics,
      application: collect_application_metrics,
      trading: collect_trading_metrics
    }

    execution_time = Time.current - start_time
    metrics[:collection_time_ms] = (execution_time * 1000).round(2)

    # Store metrics in cache for dashboard access
    Rails.cache.write('hf_performance_metrics', metrics, expires_in: 2.minutes)

    # Check for performance alerts
    check_performance_alerts(metrics)

    metrics
  end

  # Monitor high-frequency job performance
  def monitor_job_performance
    job_metrics = {}

    # Get recent job executions for high-frequency jobs
    hf_job_classes = [
      'HighFrequencyMarketDataJob',
      'HighFrequency1mCandleJob', 
      'HighFrequencyPnLTrackingJob',
      'HighFrequencyPositionMonitorJob',
      'HighFrequencySignalGenerationJob'
    ]

    hf_job_classes.each do |job_class|
      job_metrics[job_class] = analyze_job_performance(job_class)
    end

    # Overall job system health
    job_metrics['overall'] = {
      total_jobs_last_hour: count_jobs_last_hour,
      failed_jobs_last_hour: count_failed_jobs_last_hour,
      average_execution_time: calculate_average_execution_time,
      queue_depth: GoodJob::Job.where(finished_at: nil).count
    }

    job_metrics
  end

  # Check for performance degradation and alerts
  def check_performance_alerts(metrics)
    alerts = []

    # System resource alerts
    if metrics[:system][:memory_usage_percent] > 85
      alerts << create_alert('high_memory', 'Memory usage above 85%', metrics[:system][:memory_usage_percent])
    end

    if metrics[:system][:cpu_usage_percent] > 80
      alerts << create_alert('high_cpu', 'CPU usage above 80%', metrics[:system][:cpu_usage_percent])
    end

    # Database performance alerts
    if metrics[:database][:avg_query_time_ms] > 100
      alerts << create_alert('slow_database', 'Average query time above 100ms', metrics[:database][:avg_query_time_ms])
    end

    if metrics[:database][:active_connections] > 80
      alerts << create_alert('high_db_connections', 'Database connections above 80', metrics[:database][:active_connections])
    end

    # Job queue alerts
    if metrics[:job_queue][:queue_depth] > 100
      alerts << create_alert('high_queue_depth', 'Job queue depth above 100', metrics[:job_queue][:queue_depth])
    end

    if metrics[:job_queue][:failed_jobs_last_hour] > 10
      alerts << create_alert('high_job_failures', 'More than 10 job failures in last hour', metrics[:job_queue][:failed_jobs_last_hour])
    end

    # Trading system alerts
    if metrics[:trading][:stale_price_data_count] > 0
      alerts << create_alert('stale_price_data', 'Stale price data detected', metrics[:trading][:stale_price_data_count])
    end

    # Process alerts
    if alerts.any?
      process_alerts(alerts)
    end

    alerts
  end

  # Generate performance report for high-frequency operations
  def generate_performance_report(period_hours: 1)
    end_time = Time.current
    start_time = end_time - period_hours.hours

    report = {
      period: "#{period_hours} hours",
      start_time: start_time,
      end_time: end_time,
      job_performance: {},
      system_performance: {},
      trading_performance: {},
      recommendations: []
    }

    # Analyze job performance over period
    report[:job_performance] = analyze_period_job_performance(start_time, end_time)
    
    # Analyze system performance trends
    report[:system_performance] = analyze_system_performance_trends(period_hours)
    
    # Analyze trading performance
    report[:trading_performance] = analyze_trading_performance(start_time, end_time)
    
    # Generate recommendations
    report[:recommendations] = generate_performance_recommendations(report)

    report
  end

  private

  def collect_system_resource_metrics
    {
      memory_usage_mb: get_memory_usage,
      memory_usage_percent: get_memory_usage_percent,
      cpu_usage_percent: get_cpu_usage_percent,
      disk_usage_percent: get_disk_usage_percent,
      load_average: get_load_average
    }
  end

  def collect_database_metrics
    # Database connection and performance metrics
    db_stats = ActiveRecord::Base.connection.execute(
      "SELECT count(*) as active_connections FROM pg_stat_activity WHERE state = 'active'"
    ).first

    # Query performance metrics (simplified)
    {
      active_connections: db_stats['active_connections'],
      total_connections: get_total_db_connections,
      avg_query_time_ms: get_average_query_time,
      slow_queries_count: count_slow_queries,
      table_sizes: get_critical_table_sizes
    }
  end

  def collect_job_queue_metrics
    {
      queue_depth: GoodJob::Job.where(finished_at: nil).count,
      jobs_last_minute: GoodJob::Job.where('created_at > ?', 1.minute.ago).count,
      failed_jobs_last_hour: count_failed_jobs_last_hour,
      avg_execution_time_ms: calculate_average_execution_time,
      high_frequency_queue_depth: GoodJob::Job.where(queue_name: 'high_frequency', finished_at: nil).count
    }
  end

  def collect_application_metrics
    {
      rails_cache_hit_rate: calculate_cache_hit_rate,
      active_record_query_count: get_query_count_last_minute,
      response_time_ms: get_average_response_time,
      memory_bloat_mb: calculate_memory_bloat
    }
  end

  def collect_trading_metrics
    {
      open_positions_count: Position.open.count,
      day_trading_positions_count: Position.open_day_trading_positions.count,
      stale_price_data_count: count_stale_price_data,
      last_market_data_update: get_last_market_data_update,
      total_unrealized_pnl: get_cached_portfolio_metric(:total_unrealized_pnl) || 0
    }
  end

  def analyze_job_performance(job_class)
    recent_jobs = GoodJob::Job.where(job_class: job_class)
                             .where('created_at > ?', 1.hour.ago)
                             .order(:created_at)

    return { status: 'no_data' } if recent_jobs.empty?

    execution_times = recent_jobs.where.not(finished_at: nil)
                                .map { |job| job.finished_at - job.performed_at }
                                .compact

    {
      total_executions: recent_jobs.count,
      successful_executions: recent_jobs.where(error: nil).count,
      failed_executions: recent_jobs.where.not(error: nil).count,
      avg_execution_time_ms: execution_times.any? ? (execution_times.sum / execution_times.size * 1000).round(2) : 0,
      max_execution_time_ms: execution_times.any? ? (execution_times.max * 1000).round(2) : 0,
      success_rate: recent_jobs.count > 0 ? (recent_jobs.where(error: nil).count.to_f / recent_jobs.count * 100).round(2) : 0
    }
  end

  def create_alert(type, message, value)
    {
      type: type,
      message: message,
      value: value,
      timestamp: Time.current,
      severity: determine_alert_severity(type, value)
    }
  end

  def determine_alert_severity(type, value)
    case type
    when 'high_memory', 'high_cpu'
      value > 95 ? 'critical' : 'warning'
    when 'slow_database'
      value > 500 ? 'critical' : 'warning'
    when 'high_job_failures'
      value > 20 ? 'critical' : 'warning'
    else
      'warning'
    end
  end

  def process_alerts(alerts)
    alerts.each do |alert|
      @logger.warn("[HF Performance Alert] #{alert[:severity].upcase}: #{alert[:message]} (#{alert[:value]})")
      
      # TODO: Integrate with alerting system (Slack, email, etc.)
      # AlertingService.send_alert(alert)
    end

    # Store alerts for dashboard
    Rails.cache.write('hf_performance_alerts', alerts, expires_in: 10.minutes)
  end

  # Helper methods for system metrics (simplified implementations)
  
  def get_memory_usage
    return 0 unless defined?(GC)
    
    gc_stats = GC.stat
    (gc_stats[:heap_allocated_pages] * gc_stats[:heap_page_size]) / (1024 * 1024)
  rescue
    0
  end

  def get_memory_usage_percent
    # Simplified - in production, use system tools
    50 + rand(30) # Mock value
  end

  def get_cpu_usage_percent
    # Simplified - in production, use system tools like `top` or `/proc/stat`
    20 + rand(40) # Mock value
  end

  def get_disk_usage_percent
    # Simplified - in production, use `df` command
    30 + rand(20) # Mock value
  end

  def get_load_average
    # Simplified - in production, read from `/proc/loadavg`
    [1.2, 1.5, 1.8] # Mock values
  end

  def get_total_db_connections
    result = ActiveRecord::Base.connection.execute("SELECT count(*) FROM pg_stat_activity")
    result.first['count']
  rescue
    0
  end

  def get_average_query_time
    # Simplified implementation
    25 + rand(50) # Mock value in ms
  end

  def count_slow_queries
    # In production, use pg_stat_statements or log analysis
    rand(5)
  end

  def get_critical_table_sizes
    {
      positions: Position.count,
      candles: Candle.count,
      good_jobs: GoodJob::Job.count
    }
  end

  def count_failed_jobs_last_hour
    GoodJob::Job.where.not(error: nil).where('created_at > ?', 1.hour.ago).count
  end

  def count_jobs_last_hour
    GoodJob::Job.where('created_at > ?', 1.hour.ago).count
  end

  def calculate_average_execution_time
    recent_jobs = GoodJob::Job.where('finished_at > ?', 1.hour.ago)
                             .where.not(finished_at: nil, performed_at: nil)

    return 0 if recent_jobs.empty?

    execution_times = recent_jobs.map { |job| job.finished_at - job.performed_at }
    (execution_times.sum / execution_times.size * 1000).round(2)
  end

  def calculate_cache_hit_rate
    # Simplified - in production, use Redis INFO or Rails cache stats
    85 + rand(10) # Mock value
  end

  def get_query_count_last_minute
    # Simplified - in production, use query logging or APM tools
    50 + rand(100) # Mock value
  end

  def get_average_response_time
    # Simplified - in production, use APM tools
    100 + rand(200) # Mock value in ms
  end

  def calculate_memory_bloat
    # Simplified memory bloat calculation
    get_memory_usage * 0.1 # Mock value
  end

  def count_stale_price_data
    TradingPair.enabled
               .where('last_price_updated_at < ? OR last_price_updated_at IS NULL', 5.minutes.ago)
               .count
  end

  def get_last_market_data_update
    TradingPair.enabled.maximum(:last_price_updated_at)
  end

  def get_cached_portfolio_metric(metric_key)
    metrics = Rails.cache.read('portfolio_metrics')
    metrics&.dig(metric_key)
  end

  def analyze_period_job_performance(start_time, end_time)
    # Detailed analysis of job performance over time period
    # This would include trends, patterns, and anomalies
    {
      total_jobs: GoodJob::Job.where(created_at: start_time..end_time).count,
      avg_success_rate: 95.5, # Mock calculation
      performance_trend: 'stable' # Mock analysis
    }
  end

  def analyze_system_performance_trends(period_hours)
    # Analysis of system performance trends
    {
      memory_trend: 'increasing',
      cpu_trend: 'stable',
      database_trend: 'stable'
    }
  end

  def analyze_trading_performance(start_time, end_time)
    closed_positions = Position.closed.where(close_time: start_time..end_time)
    
    {
      trades_executed: closed_positions.count,
      total_pnl: closed_positions.sum(:pnl) || 0,
      win_rate: calculate_win_rate(closed_positions),
      avg_trade_duration: calculate_avg_trade_duration(closed_positions)
    }
  end

  def calculate_win_rate(positions)
    return 0 if positions.empty?
    
    winning_trades = positions.where('pnl > 0').count
    (winning_trades.to_f / positions.count * 100).round(2)
  end

  def calculate_avg_trade_duration(positions)
    durations = positions.where.not(entry_time: nil, close_time: nil)
                        .map { |p| p.close_time - p.entry_time }
    
    return 0 if durations.empty?
    
    (durations.sum / durations.size / 1.hour).round(2)
  end

  def generate_performance_recommendations(report)
    recommendations = []

    # Job performance recommendations
    if report[:job_performance][:avg_success_rate] < 95
      recommendations << "Consider investigating job failures and improving error handling"
    end

    # System performance recommendations
    if report[:system_performance][:memory_trend] == 'increasing'
      recommendations << "Monitor memory usage trends and consider optimizing memory allocation"
    end

    # Trading performance recommendations
    if report[:trading_performance][:win_rate] < 60
      recommendations << "Review trading strategy parameters and risk management rules"
    end

    recommendations
  end
end