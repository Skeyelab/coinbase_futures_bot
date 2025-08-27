# frozen_string_literal: true

# Service for broadcasting real-time trading signals via WebSocket/ActionCable
# This allows clients to receive signal alerts in real-time as they are generated
class SignalBroadcaster
  class << self
    # Broadcast a signal to all connected clients
    def broadcast(signal_data)
      return unless enabled?

      signal_payload = format_signal_payload(signal_data)

      # Broadcast to general signals channel
      ActionCable.server.broadcast('signals', signal_payload)

      # Broadcast to symbol-specific channel
      ActionCable.server.broadcast("signals:#{signal_data[:symbol]}", signal_payload) if signal_data[:symbol]

      # Broadcast to strategy-specific channel
      if signal_data[:strategy_name]
        ActionCable.server.broadcast("signals:strategy:#{signal_data[:strategy_name]}", signal_payload)
      end

      # Log successful broadcast
      Rails.logger.info("[SignalBroadcaster] Broadcast signal: #{signal_data[:symbol]} #{signal_data[:side]}@#{signal_data[:price]}")
    rescue StandardError => e
      Rails.logger.error("[SignalBroadcaster] Failed to broadcast signal: #{e.message}")
    end

    # Broadcast signal statistics
    def broadcast_stats(stats_data)
      return unless enabled?

      ActionCable.server.broadcast('signal_stats', {
                                     type: 'stats_update',
                                     timestamp: Time.current.utc.iso8601,
                                     stats: stats_data
                                   })
    rescue StandardError => e
      Rails.logger.error("[SignalBroadcaster] Failed to broadcast stats: #{e.message}")
    end

    # Broadcast system status
    def broadcast_status(status_data)
      return unless enabled?

      ActionCable.server.broadcast('signal_status', {
                                     type: 'status_update',
                                     timestamp: Time.current.utc.iso8601,
                                     status: status_data
                                   })
    rescue StandardError => e
      Rails.logger.error("[SignalBroadcaster] Failed to broadcast status: #{e.message}")
    end

    private

    def enabled?
      ENV.fetch('SIGNAL_BROADCAST_ENABLED', 'true').to_s.casecmp('true').zero?
    end

    def format_signal_payload(signal_data)
      {
        type: 'signal_alert',
        timestamp: Time.current.utc.iso8601,
        signal: {
          id: signal_data[:id],
          symbol: signal_data[:symbol],
          side: signal_data[:side],
          signal_type: signal_data[:signal_type] || 'entry',
          strategy_name: signal_data[:strategy_name],
          confidence: signal_data[:confidence],
          entry_price: signal_data[:price],
          stop_loss: signal_data[:sl],
          take_profit: signal_data[:tp],
          quantity: signal_data[:quantity],
          timeframe: signal_data[:timeframe],
          alert_status: 'active',
          alert_timestamp: Time.current.utc.iso8601,
          expires_at: calculate_expiry(signal_data[:strategy_name], signal_data[:timeframe]),
          metadata: signal_data[:metadata] || {},
          strategy_data: signal_data[:strategy_data] || {}
        }
      }
    end

    def calculate_expiry(strategy_name, timeframe)
      case strategy_name
      when 'MultiTimeframeSignal'
        case timeframe
        when '1m' then 2.minutes.from_now.utc.iso8601
        when '5m' then 5.minutes.from_now.utc.iso8601
        when '15m' then 15.minutes.from_now.utc.iso8601
        when '1h' then 1.hour.from_now.utc.iso8601
        else 30.minutes.from_now.utc.iso8601
        end
      else
        15.minutes.from_now.utc.iso8601
      end
    end
  end
end
