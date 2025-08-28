# frozen_string_literal: true

# Action Cable channel for real-time trading signal broadcasts
# Clients can subscribe to receive signal alerts as they are generated
class SignalsChannel < ApplicationCable::Channel
  def subscribed
    # Subscribe to general signals stream
    stream_from "signals"

    # Subscribe to symbol-specific streams if specified
    stream_from "signals:#{params[:symbol]}" if params[:symbol]

    # Subscribe to strategy-specific streams if specified
    stream_from "signals:strategy:#{params[:strategy]}" if params[:strategy]

    # Subscribe to stats and status streams
    stream_from "signal_stats"
    stream_from "signal_status"

    # Send welcome message
    transmit({
      type: "connection_established",
      timestamp: Time.current.utc.iso8601,
      message: "Connected to SignalsChannel",
      subscriptions: subscription_info
    })
  end

  def unsubscribed
    # Cleanup when client disconnects
    Rails.logger.info("[SignalsChannel] Client disconnected from #{subscription_info}")
  end

  # Allow clients to request current active signals
  def get_active_signals(data)
    signals = SignalAlert.active
      .order(confidence: :desc, alert_timestamp: :desc)
      .limit(data["limit"] || 10)

    transmit({
      type: "active_signals_response",
      timestamp: Time.current.utc.iso8601,
      signals: signals.map(&:to_api_response)
    })
  end

  # Allow clients to request signal statistics
  def get_stats(data)
    hours = data["hours"] || 24
    start_time = hours.to_i.hours.ago

    stats = {
      active_signals: SignalAlert.active.count,
      recent_signals: SignalAlert.where("alert_timestamp >= ?", start_time).count,
      high_confidence_signals: SignalAlert.where("alert_timestamp >= ? AND confidence >= ?", start_time, 70).count,
      signals_by_symbol: SignalAlert.where("alert_timestamp >= ?", start_time)
        .group(:symbol)
        .count,
      signals_by_strategy: SignalAlert.where("alert_timestamp >= ?", start_time)
        .group(:strategy_name)
        .count
    }

    transmit({
      type: "stats_response",
      timestamp: Time.current.utc.iso8601,
      stats: stats,
      time_range_hours: hours
    })
  end

  private

  def subscription_info
    info = ["signals"]
    info << "signals:#{params[:symbol]}" if params[:symbol]
    info << "signals:strategy:#{params[:strategy]}" if params[:strategy]
    info << "signal_stats"
    info << "signal_status"
    info.join(", ")
  end
end
