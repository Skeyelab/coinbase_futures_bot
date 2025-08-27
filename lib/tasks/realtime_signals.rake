# frozen_string_literal: true

namespace :realtime do
  desc "Start real-time signal evaluation system"
  task signals: :environment do
    Rails.logger.info("[RTS] Starting real-time signal evaluation system...")

    # Start market data subscriptions with real-time candle aggregation
    start_market_data_subscriptions

    # Start real-time signal evaluation
    start_signal_evaluation

    # Keep the process alive
    Rails.logger.info("[RTS] Real-time signal system started. Press Ctrl+C to stop.")
    trap_signals

    loop do
      sleep 1
    end
  end

  desc "Start real-time signal evaluation job only (for use with existing market data)"
  task signal_job: :environment do
    Rails.logger.info("[RTS] Starting real-time signal evaluation job...")

    # Start real-time signal evaluation
    start_signal_evaluation

    # Keep the process alive
    Rails.logger.info("[RTS] Real-time signal job started. Press Ctrl+C to stop.")
    trap_signals

    loop do
      sleep 1
    end
  end

  desc "Evaluate signals once for all pairs"
  task evaluate: :environment do
    Rails.logger.info("[RTS] Evaluating signals for all pairs...")

    evaluator = RealTimeSignalEvaluator.new(logger: Rails.logger)
    evaluator.evaluate_all_pairs

    Rails.logger.info("[RTS] Signal evaluation completed.")
  end

  desc "Evaluate signals for specific symbol"
  task :evaluate_symbol, [:symbol] => :environment do |_t, args|
    symbol = args[:symbol]
    if symbol.blank?
      Rails.logger.error("[RTS] Please provide a symbol: rake realtime:evaluate_symbol[BTC-USD]")
      exit 1
    end

    Rails.logger.info("[RTS] Evaluating signals for #{symbol}...")

    trading_pair = TradingPair.find_by(product_id: symbol)
    if trading_pair.nil?
      Rails.logger.error("[RTS] Trading pair not found: #{symbol}")
      exit 1
    end

    evaluator = RealTimeSignalEvaluator.new(logger: Rails.logger)
    evaluator.evaluate_pair(trading_pair)

    Rails.logger.info("[RTS] Signal evaluation completed for #{symbol}.")
  end

  desc "Show real-time signal statistics"
  task stats: :environment do
    hours = ENV.fetch("HOURS", "24").to_i

    Rails.logger.info("[RTS] Signal statistics for last #{hours} hours:")

    start_time = hours.hours.ago

    stats = {
      active_signals: SignalAlert.active.count,
      recent_signals: SignalAlert.where("alert_timestamp >= ?", start_time).count,
      triggered_signals: SignalAlert.where("alert_timestamp >= ? AND alert_status = ?", start_time, "triggered").count,
      expired_signals: SignalAlert.where("alert_timestamp >= ? AND alert_status = ?", start_time, "expired").count,
      high_confidence_signals: SignalAlert.where("alert_timestamp >= ? AND confidence >= ?", start_time, 70).count,
      signals_by_symbol: SignalAlert.where("alert_timestamp >= ?", start_time)
        .group(:symbol)
        .count,
      signals_by_strategy: SignalAlert.where("alert_timestamp >= ?", start_time)
        .group(:strategy_name)
        .count,
      average_confidence: SignalAlert.where("alert_timestamp >= ?", start_time)
        .average(:confidence)&.to_f&.round(2)
    }

    stats.each do |key, value|
      puts "#{key}: #{value}"
    end
  end

  desc "Clean up expired signal alerts"
  task cleanup: :environment do
    expired_count = SignalAlert.where("expires_at < ?", Time.current.utc)
      .where(alert_status: "active")
      .update_all(alert_status: "expired", updated_at: Time.current.utc)

    Rails.logger.info("[RTS] Cleaned up #{expired_count} expired signal alerts.")

    if expired_count > 0
      puts "Cleaned up #{expired_count} expired signal alerts."
    else
      puts "No expired signal alerts to clean up."
    end
  end

  desc "Cancel all active signal alerts"
  task cancel_all: :environment do
    if ENV["FORCE"] != "true"
      puts "This will cancel ALL active signal alerts. Run with FORCE=true to confirm."
      puts "Example: FORCE=true rake realtime:cancel_all"
      exit 1
    end

    cancelled_count = SignalAlert.where(alert_status: "active")
      .update_all(alert_status: "cancelled", updated_at: Time.current.utc)

    Rails.logger.info("[RTS] Cancelled #{cancelled_count} active signal alerts.")

    puts "Cancelled #{cancelled_count} active signal alerts."
  end

  private

  def start_market_data_subscriptions
    # Get all enabled trading pairs
    product_ids = TradingPair.enabled.pluck(:product_id)

    if product_ids.empty?
      Rails.logger.warn("[RTS] No enabled trading pairs found. Skipping market data subscriptions.")
      return
    end

    Rails.logger.info("[RTS] Starting market data subscriptions for #{product_ids.count} products: #{product_ids.join(", ")}")

    # Start spot market data subscription with real-time candle aggregation
    spot_subscriber = MarketData::CoinbaseSpotSubscriber.new(
      product_ids: product_ids,
      enable_candle_aggregation: true,
      logger: Rails.logger
    )

    # Start futures market data subscription with real-time candle aggregation
    futures_subscriber = MarketData::CoinbaseFuturesSubscriber.new(
      product_ids: product_ids,
      enable_candle_aggregation: true,
      logger: Rails.logger
    )

    # Start subscribers in background threads
    @spot_thread = Thread.new do
      Rails.logger.info("[RTS] Starting spot market data subscription...")
      spot_subscriber.start
    end

    @futures_thread = Thread.new do
      Rails.logger.info("[RTS] Starting futures market data subscription...")
      futures_subscriber.start
    end

    # Give threads a moment to start
    sleep 2
  end

  def start_signal_evaluation
    Rails.logger.info("[RTS] Starting real-time signal evaluation...")

    # Start the real-time signal evaluation
    RealTimeSignalJob.start_realtime_evaluation(interval_seconds: ENV.fetch("SIGNAL_EVALUATION_INTERVAL", "30").to_i)
  end

  def trap_signals
    # Handle graceful shutdown
    Signal.trap("INT") do
      Rails.logger.info("[RTS] Received INT signal, shutting down...")
      shutdown
      exit 0
    end

    Signal.trap("TERM") do
      Rails.logger.info("[RTS] Received TERM signal, shutting down...")
      shutdown
      exit 0
    end
  end

  def shutdown
    Rails.logger.info("[RTS] Shutting down real-time signal system...")

    # Stop background threads
    @spot_thread&.kill if @spot_thread&.alive?
    @futures_thread&.kill if @futures_thread&.alive?

    # Final cleanup
    realtime_cleanup

    Rails.logger.info("[RTS] Real-time signal system shut down complete.")
  end

  def realtime_cleanup
    # Clean up expired alerts
    expired_count = SignalAlert.where("expires_at < ?", Time.current.utc)
      .where(alert_status: "active")
      .update_all(alert_status: "expired", updated_at: Time.current.utc)

    return unless expired_count > 0

    Rails.logger.info("[RTS] Cleaned up #{expired_count} expired alerts during shutdown.")
  end
end
