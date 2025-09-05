# frozen_string_literal: true

# API controller for real-time trading signals
# Provides REST endpoints to access signal alerts and trigger evaluations
class SignalController < ApplicationController
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
    limit = safe_param_to_i(params[:limit], 100)
    signals = SignalAlert.active
      .order(confidence: :desc, alert_timestamp: :desc)
      .limit(limit)

    signals = filter_signals(signals)

    render json: {
      signals: signals.map(&:to_api_response),
      count: signals.count
    }
  end

  # GET /signals/high_confidence - Get high confidence signals only
  def high_confidence
    threshold = safe_param_to_f(params[:threshold], 70)
    limit = safe_param_to_i(params[:limit], 50)
    signals = SignalAlert.active
      .high_confidence(threshold)
      .order(confidence: :desc, alert_timestamp: :desc)
      .limit(limit)

    signals = filter_signals(signals)

    render json: {
      signals: signals.map(&:to_api_response),
      threshold: params[:threshold] || "70", # Echo back original parameter or default as string
      count: signals.count
    }
  end

  # GET /signals/recent - Get recently generated signals
  def recent
    hours = safe_param_to_i(params[:hours], 1)
    limit = safe_param_to_i(params[:limit], 100)
    signals = SignalAlert.recent(hours)
      .order(alert_timestamp: :desc)
      .limit(limit)

    signals = filter_signals(signals)

    render json: {
      signals: signals.map(&:to_api_response),
      hours: params[:hours] || "1", # Echo back original parameter or default as string
      count: signals.count
    }
  end

  # GET /signals/stats - Get signal statistics
  def stats
    time_range = params[:hours] || 24
    start_time = time_range.to_i.hours.ago

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
      time_range_hours: time_range.to_s
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
    signals = signals.for_symbol(params[:symbol]) if params[:symbol]

    # Filter by strategy
    signals = signals.by_strategy(params[:strategy]) if params[:strategy]

    # Filter by side
    signals = signals.by_side(params[:side]) if params[:side]

    # Filter by signal type
    signals = signals.where(signal_type: params[:signal_type]) if params[:signal_type]

    # Filter by minimum confidence
    if params[:min_confidence].present?
      min_confidence = params[:min_confidence].to_f
      signals = signals.where("confidence >= ?", min_confidence) if min_confidence > 0
    end

    # Filter by maximum confidence
    if params[:max_confidence].present?
      max_confidence = params[:max_confidence].to_f
      signals = signals.where("confidence <= ?", max_confidence) if max_confidence > 0
    end

    signals
  end

  def authenticate_request
    # Simple API key authentication
    api_key = request.headers["X-API-Key"] || params[:api_key]
    expected_key = ENV["SIGNALS_API_KEY"]

    # Allow request if no API key is configured OR if API key matches
    return if expected_key.nil? || api_key == expected_key

    render json: {error: "Unauthorized"}, status: :unauthorized
  end

  def set_cors_headers
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-API-Key"
  end

  # Helper method to safely convert parameters to numbers
  def safe_param_to_i(param, default = nil)
    return default if param.blank?

    param.to_i.positive? ? param.to_i : default
  end

  def safe_param_to_f(param, default = nil)
    return default if param.blank?

    value = param.to_f
    value.positive? ? value : default
  end
end
