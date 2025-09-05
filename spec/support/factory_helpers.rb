# frozen_string_literal: true

# Helper methods for efficient test data creation
module FactoryHelpers
  # Bulk create signal alerts without triggering individual callbacks
  # This avoids savepoint issues when creating large datasets
  def self.bulk_create_signal_alerts(count, attributes = {})
    # Use insert_all for maximum performance
    SignalAlert.insert_all(
      count.times.map do |i|
        {
          symbol: attributes[:symbol] || "BTC-USD",
          side: attributes[:side] || "long",
          signal_type: attributes[:signal_type] || "entry",
          strategy_name: attributes[:strategy_name] || "MultiTimeframeSignal",
          confidence: attributes[:confidence] || 75,
          entry_price: attributes[:entry_price] || 50_000.0,
          stop_loss: attributes[:stop_loss] || 49_000.0,
          take_profit: attributes[:take_profit] || 52_000.0,
          quantity: attributes[:quantity] || 10,
          timeframe: attributes[:timeframe] || "15m",
          alert_status: attributes[:alert_status] || "active",
          alert_timestamp: attributes[:alert_timestamp] || Time.current.utc,
          expires_at: attributes[:expires_at] || 15.minutes.from_now.utc,
          metadata: attributes[:metadata] || {"test" => "metadata"},
          strategy_data: attributes[:strategy_data] || {"ema_short" => 49_900, "ema_long" => 49_800},
          created_at: Time.current.utc,
          updated_at: Time.current.utc
        }
      end
    )
  end

  # Create signal alerts in batches to avoid database timeouts
  def self.create_signal_alerts_in_batches(count, batch_size: 50, attributes: {})
    total_created = 0

    while total_created < count
      batch_count = [batch_size, count - total_created].min
      bulk_create_signal_alerts(batch_count, attributes)
      total_created += batch_count
    end

    total_created
  end
end
