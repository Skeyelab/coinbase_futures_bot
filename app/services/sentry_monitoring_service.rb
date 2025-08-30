# frozen_string_literal: true

# Service for tracking business metrics and custom events in Sentry
class SentryMonitoringService
  class << self
    # Track trading signals with comprehensive context
    def track_signal_generated(signal_data)
      return unless enabled?

      Sentry.with_scope do |scope|
        scope.set_tag("event_type", "signal_generated")
        scope.set_tag("signal_side", signal_data[:side])
        scope.set_tag("signal_type", signal_data[:signal_type])
        scope.set_tag("strategy", signal_data[:strategy_name])
        scope.set_tag("symbol", signal_data[:symbol])
        scope.set_tag("confidence_tier", confidence_tier(signal_data[:confidence]))

        scope.set_context("signal", {
          symbol: signal_data[:symbol],
          side: signal_data[:side],
          signal_type: signal_data[:signal_type],
          strategy_name: signal_data[:strategy_name],
          confidence: signal_data[:confidence],
          entry_price: signal_data[:entry_price],
          take_profit: signal_data[:take_profit],
          stop_loss: signal_data[:stop_loss],
          timeframe: signal_data[:timeframe]
        })

        Sentry.capture_message("Trading signal generated", level: "info")
      end
    end

    # Track position operations
    def track_position_opened(position_data)
      return unless enabled?

      Sentry.with_scope do |scope|
        scope.set_tag("event_type", "position_opened")
        scope.set_tag("position_side", position_data[:side])
        scope.set_tag("product_id", position_data[:product_id])
        scope.set_tag("trading_mode", (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live")
        scope.set_tag("day_trading", position_data[:day_trading])

        scope.set_context("position", {
          product_id: position_data[:product_id],
          side: position_data[:side],
          size: position_data[:size],
          entry_price: position_data[:entry_price],
          day_trading: position_data[:day_trading],
          trading_mode: (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live"
        })

        Sentry.capture_message("Trading position opened", level: "info")
      end
    end

    # Track position closures
    def track_position_closed(position_data, closure_reason)
      return unless enabled?

      Sentry.with_scope do |scope|
        scope.set_tag("event_type", "position_closed")
        scope.set_tag("position_side", position_data[:side])
        scope.set_tag("product_id", position_data[:product_id])
        scope.set_tag("closure_reason", closure_reason)
        scope.set_tag("trading_mode", (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live")

        # Calculate P&L if available
        pnl = calculate_pnl(position_data)
        scope.set_tag("pnl_category", pnl_category(pnl)) if pnl

        scope.set_context("position_closure", {
          product_id: position_data[:product_id],
          side: position_data[:side],
          size: position_data[:size],
          entry_price: position_data[:entry_price],
          close_price: position_data[:close_price],
          pnl: pnl,
          closure_reason: closure_reason,
          duration_hours: position_data[:duration_hours],
          trading_mode: (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live"
        })

        level = (pnl && pnl < 0) ? "warning" : "info"
        Sentry.capture_message("Trading position closed", level: level)
      end
    end

    # Track market data events
    def track_market_data_event(event_type, data = {})
      return unless enabled?

      SentryHelper.add_breadcrumb(
        message: "Market data event",
        category: "market_data",
        level: "info",
        data: {
          event_type: event_type
        }.merge(data)
      )
    end

    # Track sentiment analysis events
    def track_sentiment_event(event_type, data = {})
      return unless enabled?

      SentryHelper.add_breadcrumb(
        message: "Sentiment analysis event",
        category: "sentiment",
        level: "info",
        data: {
          event_type: event_type
        }.merge(data)
      )
    end

    # Track API rate limiting events
    def track_rate_limit_hit(service, endpoint, retry_after = nil)
      return unless enabled?

      Sentry.with_scope do |scope|
        scope.set_tag("event_type", "rate_limit_hit")
        scope.set_tag("service", service)
        scope.set_tag("endpoint", endpoint)

        scope.set_context("rate_limit", {
          service: service,
          endpoint: endpoint,
          retry_after: retry_after,
          timestamp: Time.current.utc.iso8601
        })

        Sentry.capture_message("API rate limit exceeded", level: "warning")
      end
    end

    # Track system health events
    def track_health_check(health_data, overall_healthy)
      return unless enabled?

      level = overall_healthy ? "info" : "error"

      Sentry.with_scope do |scope|
        scope.set_tag("event_type", "health_check")
        scope.set_tag("overall_healthy", overall_healthy)
        scope.set_tag("database_ok", health_data[:database])
        scope.set_tag("coinbase_api_ok", health_data[:coinbase_api])
        scope.set_tag("background_jobs_ok", health_data[:background_jobs])

        scope.set_context("health_check", health_data)

        message = overall_healthy ? "System health check passed" : "System health check failed"
        Sentry.capture_message(message, level: level)
      end
    end

    # Track critical trading events
    def track_critical_trading_event(event_type, message, data = {})
      return unless enabled?

      Sentry.with_scope do |scope|
        scope.set_tag("event_type", "critical_trading_event")
        scope.set_tag("trading_event", event_type)
        scope.set_tag("critical", "true")

        scope.set_context("critical_event", {
          event_type: event_type,
          timestamp: Time.current.utc.iso8601,
          trading_mode: (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live"
        }.merge(data))

        Sentry.capture_message(message, level: "error")
      end
    end

    private

    def enabled?
      defined?(Sentry) && ENV["SENTRY_DSN"].present?
    end

    def confidence_tier(confidence)
      case confidence.to_f
      when 0..30
        "low"
      when 30..60
        "medium"
      when 60..80
        "high"
      when 80..100
        "very_high"
      else
        "unknown"
      end
    end

    def calculate_pnl(position_data)
      return nil unless position_data[:entry_price] && position_data[:close_price] && position_data[:size]

      entry = position_data[:entry_price].to_f
      close = position_data[:close_price].to_f
      size = position_data[:size].to_f
      side = position_data[:side]

      if side == "LONG"
        (close - entry) * size
      elsif side == "SHORT"
        (entry - close) * size
      end
    end

    def pnl_category(pnl)
      return "unknown" unless pnl.is_a?(Numeric)

      case pnl
      when Float::INFINITY, -Float::INFINITY
        "invalid"
      when -Float::INFINITY..-1000
        "large_loss"
      when -1000..-100
        "medium_loss"
      when -100..0
        "small_loss"
      when 0..100
        "small_profit"
      when 100..1000
        "medium_profit"
      else
        "large_profit"
      end
    end
  end
end
