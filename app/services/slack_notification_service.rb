# frozen_string_literal: true

class SlackNotificationService
  class << self
    # Send a trading signal notification
    def signal_generated(signal_data)
      return unless enabled?

      message = format_signal_message(signal_data)
      send_message(message, channel: signals_channel)
    end

    # Send position update notification
    def position_update(position, action)
      return unless enabled?

      message = format_position_message(position, action)
      send_message(message, channel: positions_channel)
    end

    # Send bot status notification
    def bot_status(status_data)
      return unless enabled?

      message = format_status_message(status_data)
      send_message(message, channel: status_channel)
    end

    # Send error/alert notification
    def alert(level, title, details = nil)
      return unless enabled?

      message = format_alert_message(level, title, details)
      channel = case level.to_s.downcase
      when "critical", "error"
        alerts_channel
      else
        status_channel
      end
      send_message(message, channel: channel)
    end

    # Send PnL update notification
    def pnl_update(pnl_data)
      return unless enabled?

      message = format_pnl_message(pnl_data)
      send_message(message, channel: positions_channel)
    end

    # Send health check notification
    def health_check(health_data)
      return unless enabled?

      message = format_health_message(health_data)
      send_message(message, channel: status_channel)
    end

    # Send market condition alert
    def market_alert(market_data)
      return unless enabled?

      message = format_market_message(market_data)
      send_message(message, channel: alerts_channel)
    end

    private

    def enabled?
      ENV["SLACK_ENABLED"]&.downcase == "true" && bot_token.present?
    end

    def bot_token
      ENV["SLACK_BOT_TOKEN"]
    end

    def signals_channel
      ENV["SLACK_SIGNALS_CHANNEL"] || "#trading-signals"
    end

    def positions_channel
      ENV["SLACK_POSITIONS_CHANNEL"] || "#trading-positions"
    end

    def status_channel
      ENV["SLACK_STATUS_CHANNEL"] || "#bot-status"
    end

    def alerts_channel
      ENV["SLACK_ALERTS_CHANNEL"] || "#trading-alerts"
    end

    def client
      @client ||= Slack::Web::Client.new(token: bot_token)
    end

    def send_message(message, channel:)
      return unless message.present?

      retries = 0
      max_retries = 3

      begin
        client.chat_postMessage(
          channel: channel,
          text: message[:text],
          attachments: message[:attachments],
          blocks: message[:blocks]
        )
        Rails.logger.info("[Slack] Message sent to #{channel}")
      rescue Slack::Web::Api::Errors::SlackError => e
        Rails.logger.error("[Slack] API Error: #{e.message}")

        retries += 1
        if retries <= max_retries
          sleep(2**retries) # Exponential backoff
          retry
        else
          Rails.logger.error("[Slack] Failed to send message after #{max_retries} retries")
        end
      rescue => e
        Rails.logger.error("[Slack] Unexpected error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
      end
    end

    def format_signal_message(signal_data)
      symbol = signal_data[:symbol] || signal_data[:product_id]
      side = signal_data[:side]
      price = signal_data[:price]&.round(2)
      quantity = signal_data[:quantity]
      confidence = signal_data[:confidence]
      tp = signal_data[:tp]&.round(2)
      sl = signal_data[:sl]&.round(2)

      color = case side.to_s.downcase
      when "long", "buy"
        "good"
      when "short", "sell"
        "danger"
      else
        "warning"
      end

      {
        text: "🎯 New Trading Signal: #{symbol}",
        attachments: [
          {
            color: color,
            fields: [
              {
                title: "Symbol",
                value: symbol,
                short: true
              },
              {
                title: "Side",
                value: side.to_s.upcase,
                short: true
              },
              {
                title: "Price",
                value: "$#{price}",
                short: true
              },
              {
                title: "Quantity",
                value: quantity.to_s,
                short: true
              },
              {
                title: "Take Profit",
                value: tp ? "$#{tp}" : "N/A",
                short: true
              },
              {
                title: "Stop Loss",
                value: sl ? "$#{sl}" : "N/A",
                short: true
              },
              {
                title: "Confidence",
                value: confidence ? "#{confidence}%" : "N/A",
                short: true
              },
              {
                title: "Timestamp",
                value: Time.current.strftime("%Y-%m-%d %H:%M:%S UTC"),
                short: true
              }
            ]
          }
        ]
      }
    end

    def format_position_message(position, action)
      action_emoji = case action.to_s.downcase
      when "opened"
        "🟢"
      when "closed"
        "🔴"
      when "updated"
        "🔄"
      else
        "📊"
      end

      color = case action.to_s.downcase
      when "opened"
        "good"
      when "closed"
        position.pnl&.positive? ? "good" : "danger"
      else
        "warning"
      end

      fields = [
        {
          title: "Symbol",
          value: position.product_id,
          short: true
        },
        {
          title: "Side",
          value: position.side.upcase,
          short: true
        },
        {
          title: "Size",
          value: position.size.to_s,
          short: true
        },
        {
          title: "Entry Price",
          value: "$#{position.entry_price&.round(2)}",
          short: true
        }
      ]

      if position.pnl
        fields << {
          title: "PnL",
          value: "$#{position.pnl.round(2)}",
          short: true
        }
      end

      if position.close_time
        fields << {
          title: "Duration",
          value: duration_in_words(position.entry_time, position.close_time),
          short: true
        }
      end

      {
        text: "#{action_emoji} Position #{action.capitalize}: #{position.product_id}",
        attachments: [
          {
            color: color,
            fields: fields
          }
        ]
      }
    end

    def format_status_message(status_data)
      {
        text: "🤖 Bot Status Update",
        attachments: [
          {
            color: status_data[:healthy] ? "good" : "danger",
            fields: [
              {
                title: "Status",
                value: status_data[:status] || "Unknown",
                short: true
              },
              {
                title: "Trading Active",
                value: status_data[:trading_active] ? "✅" : "❌",
                short: true
              },
              {
                title: "Open Positions",
                value: status_data[:open_positions] || 0,
                short: true
              },
              {
                title: "Daily PnL",
                value: status_data[:daily_pnl] ? "$#{status_data[:daily_pnl].round(2)}" : "N/A",
                short: true
              },
              {
                title: "Last Signal",
                value: status_data[:last_signal_time] || "N/A",
                short: true
              },
              {
                title: "Timestamp",
                value: Time.current.strftime("%Y-%m-%d %H:%M:%S UTC"),
                short: true
              }
            ]
          }
        ]
      }
    end

    def format_alert_message(level, title, details)
      emoji = case level.to_s.downcase
      when "critical"
        "🚨"
      when "error"
        "❌"
      when "warning"
        "⚠️"
      when "info"
        "ℹ️"
      else
        "📢"
      end

      color = case level.to_s.downcase
      when "critical", "error"
        "danger"
      when "warning"
        "warning"
      else
        "good"
      end

      fields = [
        {
          title: "Level",
          value: level.to_s.upcase,
          short: true
        },
        {
          title: "Timestamp",
          value: Time.current.strftime("%Y-%m-%d %H:%M:%S UTC"),
          short: true
        }
      ]

      if details.present?
        fields << {
          title: "Details",
          value: details.to_s,
          short: false
        }
      end

      {
        text: "#{emoji} Alert: #{title}",
        attachments: [
          {
            color: color,
            fields: fields
          }
        ]
      }
    end

    def format_pnl_message(pnl_data)
      total_pnl = pnl_data[:total_pnl]
      color = total_pnl&.positive? ? "good" : "danger"
      emoji = total_pnl&.positive? ? "📈" : "📉"

      {
        text: "#{emoji} PnL Update",
        attachments: [
          {
            color: color,
            fields: [
              {
                title: "Total PnL",
                value: "$#{total_pnl&.round(2)}",
                short: true
              },
              {
                title: "Daily PnL",
                value: "$#{pnl_data[:daily_pnl]&.round(2)}",
                short: true
              },
              {
                title: "Open Positions",
                value: pnl_data[:open_positions] || 0,
                short: true
              },
              {
                title: "Closed Positions Today",
                value: pnl_data[:closed_today] || 0,
                short: true
              },
              {
                title: "Win Rate",
                value: pnl_data[:win_rate] ? "#{pnl_data[:win_rate].round(1)}%" : "N/A",
                short: true
              },
              {
                title: "Timestamp",
                value: Time.current.strftime("%Y-%m-%d %H:%M:%S UTC"),
                short: true
              }
            ]
          }
        ]
      }
    end

    def format_health_message(health_data)
      overall_health = health_data[:overall_health]
      color = case overall_health
      when "healthy"
        "good"
      when "warning"
        "warning"
      else
        "danger"
      end

      emoji = case overall_health
      when "healthy"
        "✅"
      when "warning"
        "⚠️"
      else
        "❌"
      end

      {
        text: "#{emoji} Health Check",
        attachments: [
          {
            color: color,
            fields: [
              {
                title: "Overall Health",
                value: overall_health.to_s.capitalize,
                short: true
              },
              {
                title: "Database",
                value: health_data[:database] ? "✅" : "❌",
                short: true
              },
              {
                title: "Coinbase API",
                value: health_data[:coinbase_api] ? "✅" : "❌",
                short: true
              },
              {
                title: "Background Jobs",
                value: health_data[:background_jobs] ? "✅" : "❌",
                short: true
              },
              {
                title: "WebSocket Connections",
                value: health_data[:websocket_connections] || 0,
                short: true
              },
              {
                title: "Last Check",
                value: Time.current.strftime("%Y-%m-%d %H:%M:%S UTC"),
                short: true
              }
            ]
          }
        ]
      }
    end

    def format_market_message(market_data)
      {
        text: "📊 Market Alert",
        attachments: [
          {
            color: "warning",
            fields: [
              {
                title: "Alert Type",
                value: market_data[:alert_type],
                short: true
              },
              {
                title: "Symbol",
                value: market_data[:symbol],
                short: true
              },
              {
                title: "Current Price",
                value: "$#{market_data[:current_price]&.round(2)}",
                short: true
              },
              {
                title: "Volatility",
                value: market_data[:volatility] ? "#{market_data[:volatility].round(2)}%" : "N/A",
                short: true
              },
              {
                title: "Volume",
                value: market_data[:volume] || "N/A",
                short: true
              },
              {
                title: "Timestamp",
                value: Time.current.strftime("%Y-%m-%d %H:%M:%S UTC"),
                short: true
              }
            ]
          }
        ]
      }
    end

    def duration_in_words(start_time, end_time)
      return "N/A" unless start_time && end_time

      duration_seconds = end_time - start_time
      hours = (duration_seconds / 3600).to_i
      minutes = ((duration_seconds % 3600) / 60).to_i

      if hours > 0
        "#{hours}h #{minutes}m"
      else
        "#{minutes}m"
      end
    end
  end
end
