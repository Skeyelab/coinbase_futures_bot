# frozen_string_literal: true

# API controller for real-time trading signals
# Provides REST endpoints to access signal alerts and trigger evaluations
class SignalsController < ApplicationController
  before_action :authenticate_request, except: [:health]
  before_action :set_cors_headers

  # GET /signals - List all active signals
  def index
    signals = SignalAlert.includes(:trading_pair)
      .active
      .order(confidence: :desc, alert_timestamp: :desc)

    # Apply filters
    signals = filter_signals(signals)

    # Paginate results
    signals = signals.page(params[:page]).per(params[:per_page] || 50)

    render json: {
      signals: signals.map(&:to_api_response),
      meta: {
        total_count: signals.total_count,
        current_page: signals.current_page,
        per_page: signals.limit_value,
        total_pages: signals.total_pages
      }
    }
  end

  # GET /signals/:id - Show specific signal
  def show
    signal = SignalAlert.find(params[:id])
    render json: signal.to_api_response
  rescue ActiveRecord::RecordNotFound
    render json: {error: "Signal not found"}, status: :not_found
  end

  # POST /signals/evaluate - Trigger real-time signal evaluation
  def evaluate
    # Add Sentry breadcrumb for signal evaluation
    SentryHelper.add_breadcrumb(
      message: "Signal evaluation requested",
      category: "trading",
      level: "info",
      data: {
        controller: "signal",
        action: "evaluate",
        symbol: params[:symbol]
      }
    )

    evaluator = RealTimeSignalEvaluator.new(logger: Rails.logger)

    if params[:symbol]
      # Evaluate specific symbol
      trading_pair = TradingPair.find_by(product_id: params[:symbol])
      if trading_pair
        evaluator.evaluate_pair(trading_pair)

        # Track successful signal evaluation
        SentryHelper.add_breadcrumb(
          message: "Signal evaluation completed",
          category: "trading",
          level: "info",
          data: {
            symbol: params[:symbol],
            evaluation_type: "single_pair"
          }
        )

        render json: {message: "Evaluated signals for #{params[:symbol]}"}
      else
        # Track trading pair not found errors
        Sentry.with_scope do |scope|
          scope.set_tag("controller", "signal")
          scope.set_tag("error_type", "trading_pair_not_found")
          scope.set_context("request", {symbol: params[:symbol]})

          Sentry.capture_message("Trading pair not found for signal evaluation", level: "warning")
        end

        render json: {error: "Trading pair not found: #{params[:symbol]}"}, status: :not_found
      end
    else
      # Evaluate all pairs
      evaluator.evaluate_all_pairs

      # Track successful bulk evaluation
      SentryHelper.add_breadcrumb(
        message: "Bulk signal evaluation completed",
        category: "trading",
        level: "info",
        data: {
          evaluation_type: "all_pairs"
        }
      )

      render json: {message: "Evaluated signals for all enabled trading pairs"}
    end
  rescue => e
    # Enhanced error tracking for signal evaluation failures
    Sentry.with_scope do |scope|
      scope.set_tag("controller", "signal")
      scope.set_tag("action", "evaluate")
      scope.set_tag("error_type", "signal_evaluation_error")
      scope.set_tag("critical", "true")

      scope.set_context("signal_evaluation", {
        symbol: params[:symbol],
        evaluation_type: params[:symbol] ? "single_pair" : "all_pairs"
      })

      Sentry.capture_exception(e)
    end

    raise # Let ApplicationController handle the response
  end

  # GET /signals/active - Get active signals only
  def active
    limit = (params[:limit] || 100).to_i

    # Validate limit parameter (1-1000)
    limit = 100 if limit < 1 || limit > 1000

    signals = SignalAlert.active
      .order(confidence: :desc, alert_timestamp: :desc)
      .limit(limit)

    signals = filter_signals(signals)

    render json: {
      signals: signals.map(&:to_api_response),
      count: signals.count,
      limit: limit
    }
  end

  # GET /signals/high_confidence - Get high confidence signals only
  def high_confidence
    threshold = (params[:threshold] || 70).to_i
    limit = (params[:limit] || 50).to_i

    # Validate threshold parameter (0-100)
    threshold = 70 if threshold < 0 || threshold > 100

    # Validate limit parameter (1-1000)
    limit = 50 if limit < 1 || limit > 1000

    signals = SignalAlert.active
      .high_confidence(threshold)
      .order(confidence: :desc, alert_timestamp: :desc)
      .limit(limit)

    signals = filter_signals(signals)

    render json: {
      signals: signals.map(&:to_api_response),
      threshold: threshold,
      count: signals.count,
      limit: limit
    }
  end

  # GET /signals/recent - Get recently generated signals
  def recent
    hours = (params[:hours] || 1).to_i
    limit = (params[:limit] || 100).to_i

    # Validate hours parameter (1-168 hours = 1 week)
    hours = 1 if hours < 1 || hours > 168

    # Validate limit parameter (1-1000)
    limit = 100 if limit < 1 || limit > 1000

    signals = SignalAlert.recent(hours)
      .order(alert_timestamp: :desc)
      .limit(limit)

    signals = filter_signals(signals)

    render json: {
      signals: signals.map(&:to_api_response),
      hours: hours,
      count: signals.count,
      limit: limit
    }
  end

  # GET /signals/stats - Get signal statistics
  def stats
    time_range = (params[:hours] || 24).to_i

    # Validate time_range parameter (1-168 hours = 1 week)
    time_range = 24 if time_range < 1 || time_range > 168

    start_time = time_range.hours.ago

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
        .average(:confidence)&.to_f&.round(2),
      time_range_hours: time_range
    }

    render json: stats
  end

  # POST /signals/:id/trigger - Mark signal as triggered
  def trigger
    signal = SignalAlert.find(params[:id])
    signal.trigger!

    render json: {
      message: "Signal marked as triggered",
      signal: signal.to_api_response
    }
  rescue ActiveRecord::RecordNotFound
    render json: {error: "Signal not found"}, status: :not_found
  end

  # POST /signals/:id/cancel - Cancel signal
  def cancel
    signal = SignalAlert.find(params[:id])
    signal.cancel!

    render json: {
      message: "Signal cancelled",
      signal: signal.to_api_response
    }
  rescue ActiveRecord::RecordNotFound
    render json: {error: "Signal not found"}, status: :not_found
  end

  # GET /signals/health - Health check for signal system
  def health
    last_signal = SignalAlert.order(:alert_timestamp).last
    recent_signals_count = SignalAlert.where("alert_timestamp >= ?", 1.hour.ago).count

    render json: {
      status: "healthy",
      last_signal_timestamp: last_signal&.alert_timestamp,
      recent_signals_count: recent_signals_count,
      active_signals_count: SignalAlert.active.count,
      timestamp: Time.current.utc.iso8601
    }
  end

  private

  def filter_signals(signals)
    # Filter by symbol
    signals = signals.for_symbol(params[:symbol]) if params[:symbol].present?

    # Filter by strategy
    signals = signals.by_strategy(params[:strategy]) if params[:strategy].present?

    # Filter by side
    signals = signals.by_side(params[:side]) if params[:side].present?

    # Filter by signal type
    signals = signals.where(signal_type: params[:signal_type]) if params[:signal_type].present?

    # Filter by minimum confidence (validate numeric)
    if params[:min_confidence].present? && params[:min_confidence].to_s.match?(/\A\d+(\.\d+)?\z/)
      min_conf = params[:min_confidence].to_f
      signals = signals.where("confidence >= ?", min_conf) if min_conf.between?(0, 100)
    end

    # Filter by maximum confidence (validate numeric)
    if params[:max_confidence].present? && params[:max_confidence].to_s.match?(/\A\d+(\.\d+)?\z/)
      max_conf = params[:max_confidence].to_f
      signals = signals.where("confidence <= ?", max_conf) if max_conf.between?(0, 100)
    end

    signals
  end

  def authenticate_request
    # Simple API key authentication
    api_key = request.headers["X-API-Key"] || params[:api_key]
    expected_key = ENV["SIGNALS_API_KEY"]

    return if api_key == expected_key

    render json: {error: "Unauthorized"}, status: :unauthorized
  end

  def set_cors_headers
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-API-Key"
  end
end
