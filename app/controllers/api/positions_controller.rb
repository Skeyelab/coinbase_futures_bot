# frozen_string_literal: true

class Api::PositionsController < ApplicationController
  # GET /api/positions
  # GET /api/positions?type=day_trading
  # GET /api/positions?type=swing_trading
  def index
    positions = case params[:type]
    when "day_trading"
      Position.open.day_trading
    when "swing_trading"
      Position.open.swing_trading
    else
      Position.open
    end

    # Apply additional filters
    positions = positions.by_product(params[:product_id]) if params[:product_id].present?
    positions = positions.by_side(params[:side]) if params[:side].present?

    # Order and paginate
    positions = positions.order(entry_time: :desc)
    positions = positions.limit(params[:limit].to_i) if params[:limit].present?

    # Add Sentry breadcrumb for API access
    SentryHelper.add_breadcrumb(
      message: "API positions request",
      category: "api",
      level: "info",
      data: {
        controller: "api/positions",
        action: "index",
        type_filter: params[:type],
        position_count: positions.count
      }
    )

    render json: {
      positions: positions.map(&method(:serialize_position)),
      summary: {
        day_trading_count: Position.open.day_trading.count,
        swing_trading_count: Position.open.swing_trading.count,
        total_count: Position.open.count
      },
      timestamp: Time.current.utc.iso8601
    }
  rescue => e
    Rails.logger.error("[API::PositionsController] Error retrieving positions: #{e.message}")

    # Track API errors
    Sentry.with_scope do |scope|
      scope.set_tag("controller", "api/positions")
      scope.set_tag("error_type", "api_error")
      scope.set_context("positions_request", {
        type_filter: params[:type],
        product_id: params[:product_id],
        side: params[:side]
      })

      Sentry.capture_exception(e)
    end

    render json: {
      error: "Failed to retrieve positions",
      message: e.message,
      timestamp: Time.current.utc.iso8601
    }, status: :internal_server_error
  end

  # GET /api/positions/summary
  def summary
    day_positions = Position.open.day_trading
    swing_positions = Position.open.swing_trading

    # Calculate exposures and metrics
    day_exposure = calculate_exposure(day_positions)
    swing_exposure = calculate_exposure(swing_positions)

    summary_data = {
      day_trading: {
        count: day_positions.count,
        exposure_percentage: day_exposure,
        average_duration_hours: calculate_average_duration(day_positions),
        positions_approaching_closure: day_positions.where("entry_time < ?", 23.hours.ago).count,
        positions_needing_closure: day_positions.where("entry_time < ?", 24.hours.ago).count
      },
      swing_trading: {
        count: swing_positions.count,
        exposure_percentage: swing_exposure,
        average_duration_days: calculate_average_duration(swing_positions) / 24.0,
        positions_approaching_expiry: swing_positions.where("entry_time < ?", 13.days.ago).count,
        positions_exceeding_max_hold: swing_positions.where("entry_time < ?", 14.days.ago).count
      },
      overall: {
        total_positions: Position.open.count,
        total_exposure_percentage: day_exposure + swing_exposure,
        daily_pnl: Position.where(entry_time: Date.current.beginning_of_day..Time.current).sum(:pnl),
        unrealized_pnl: Position.open.sum(:pnl) || 0
      },
      timestamp: Time.current.utc.iso8601
    }

    render json: summary_data
  rescue => e
    Rails.logger.error("[API::PositionsController] Error generating summary: #{e.message}")
    render json: {
      error: "Failed to generate positions summary",
      message: e.message,
      timestamp: Time.current.utc.iso8601
    }, status: :internal_server_error
  end

  # GET /api/positions/exposure
  def exposure
    day_exposure = calculate_exposure(Position.open.day_trading)
    swing_exposure = calculate_exposure(Position.open.swing_trading)
    total_exposure = day_exposure + swing_exposure

    config = Rails.application.config.monitoring_config
    max_day_exposure = config[:max_day_trading_exposure] * 100 # Convert to percentage
    max_swing_exposure = config[:max_swing_trading_exposure] * 100

    warnings = []
    warnings << "Day trading exposure exceeds limit" if day_exposure > max_day_exposure
    warnings << "Swing trading exposure exceeds limit" if swing_exposure > max_swing_exposure

    render json: {
      day_trading_exposure: day_exposure.round(2),
      swing_trading_exposure: swing_exposure.round(2),
      total_exposure: total_exposure.round(2),
      limits: {
        max_day_trading: max_day_exposure,
        max_swing_trading: max_swing_exposure
      },
      warnings: warnings,
      healthy: warnings.empty?,
      timestamp: Time.current.utc.iso8601
    }
  rescue => e
    Rails.logger.error("[API::PositionsController] Error calculating exposure: #{e.message}")
    render json: {
      error: "Failed to calculate exposure",
      message: e.message,
      timestamp: Time.current.utc.iso8601
    }, status: :internal_server_error
  end

  private

  def serialize_position(position)
    {
      id: position.id,
      product_id: position.product_id,
      side: position.side,
      size: position.size,
      entry_price: position.entry_price,
      entry_time: position.entry_time&.utc&.iso8601,
      close_time: position.close_time&.utc&.iso8601,
      status: position.status,
      pnl: position.pnl,
      take_profit: position.take_profit,
      stop_loss: position.stop_loss,
      day_trading: position.day_trading,
      position_type: position.day_trading? ? "day_trading" : "swing_trading",
      duration_hours: position.duration_hours&.round(2),
      created_at: position.created_at.utc.iso8601,
      updated_at: position.updated_at.utc.iso8601
    }
  end

  def calculate_exposure(positions)
    return 0.0 if positions.empty?

    total_notional = positions.sum { |pos| pos.size * pos.entry_price }
    # This should be replaced with actual account balance from Coinbase
    total_portfolio_value = 100_000.0

    (total_notional / total_portfolio_value * 100).to_f
  end

  def calculate_average_duration(positions)
    return 0.0 if positions.empty?

    total_duration = positions.sum { |pos| (Time.current - pos.entry_time) / 1.hour }
    total_duration / positions.count
  end
end
