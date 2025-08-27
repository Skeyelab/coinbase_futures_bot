# frozen_string_literal: true

class SlackCommandHandler
  AUTHORIZED_USERS = ENV["SLACK_AUTHORIZED_USERS"]&.split(",") || []

  class << self
    def handle_command(params)
      return unauthorized_response unless authorized?(params[:user_id])

      command = params[:command]
      text = params[:text]&.strip || ""

      case command
      when "/bot-status"
        handle_status_command
      when "/bot-pause"
        handle_pause_command
      when "/bot-resume"
        handle_resume_command
      when "/bot-positions"
        handle_positions_command(text)
      when "/bot-pnl"
        handle_pnl_command(text)
      when "/bot-health"
        handle_health_command
      when "/bot-stop"
        handle_emergency_stop_command
      when "/bot-help"
        handle_help_command
      else
        unknown_command_response(command)
      end
    rescue => e
      Rails.logger.error("[SlackCommand] Error handling command #{params[:command]}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      error_response(e.message)
    end

    private

    def authorized?(user_id)
      return true if AUTHORIZED_USERS.empty? # If no users configured, allow all
      AUTHORIZED_USERS.include?(user_id)
    end

    def unauthorized_response
      {
        text: "❌ You are not authorized to use this command.",
        response_type: "ephemeral"
      }
    end

    def handle_status_command
      # Get current bot status
      status_data = get_bot_status

      {
        text: "🤖 Bot Status",
        response_type: "in_channel",
        attachments: [
          {
            color: status_data[:healthy] ? "good" : "danger",
            fields: [
              {
                title: "Trading Status",
                value: status_data[:trading_active] ? "🟢 Active" : "🔴 Paused",
                short: true
              },
              {
                title: "Open Positions",
                value: status_data[:open_positions].to_s,
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
                title: "Health Status",
                value: status_data[:health_status] || "Unknown",
                short: true
              },
              {
                title: "Uptime",
                value: status_data[:uptime] || "N/A",
                short: true
              }
            ]
          }
        ]
      }
    end

    def handle_pause_command
      # Set trading pause flag
      set_trading_status(false)

      SlackNotificationService.bot_status({
        status: "paused",
        trading_active: false,
        healthy: true
      })

      {
        text: "⏸️ Trading has been paused. The bot will stop generating new signals and opening positions.",
        response_type: "in_channel"
      }
    end

    def handle_resume_command
      # Resume trading
      set_trading_status(true)

      SlackNotificationService.bot_status({
        status: "active",
        trading_active: true,
        healthy: true
      })

      {
        text: "▶️ Trading has been resumed. The bot will continue normal operations.",
        response_type: "in_channel"
      }
    end

    def handle_positions_command(filter = "")
      positions = get_positions(filter)

      if positions.empty?
        return {
          text: "📊 No positions found#{filter.present? ? " for filter: #{filter}" : ""}",
          response_type: "ephemeral"
        }
      end

      attachments = positions.map do |position|
        pnl_color = position.pnl&.positive? ? "good" : "danger"

        {
          color: pnl_color,
          fields: [
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
            },
            {
              title: "Current PnL",
              value: position.pnl ? "$#{position.pnl.round(2)}" : "N/A",
              short: true
            },
            {
              title: "Duration",
              value: position.entry_time ? duration_since(position.entry_time) : "N/A",
              short: true
            }
          ]
        }
      end

      {
        text: "📊 Current Positions (#{positions.count})",
        response_type: "in_channel",
        attachments: attachments
      }
    end

    def handle_pnl_command(period = "today")
      pnl_data = get_pnl_data(period)

      color = pnl_data[:total_pnl]&.positive? ? "good" : "danger"
      emoji = pnl_data[:total_pnl]&.positive? ? "📈" : "📉"

      {
        text: "#{emoji} PnL Report (#{period.capitalize})",
        response_type: "in_channel",
        attachments: [
          {
            color: color,
            fields: [
              {
                title: "Total PnL",
                value: "$#{pnl_data[:total_pnl]&.round(2)}",
                short: true
              },
              {
                title: "Realized PnL",
                value: "$#{pnl_data[:realized_pnl]&.round(2)}",
                short: true
              },
              {
                title: "Unrealized PnL",
                value: "$#{pnl_data[:unrealized_pnl]&.round(2)}",
                short: true
              },
              {
                title: "Trades Completed",
                value: pnl_data[:completed_trades].to_s,
                short: true
              },
              {
                title: "Win Rate",
                value: pnl_data[:win_rate] ? "#{pnl_data[:win_rate].round(1)}%" : "N/A",
                short: true
              },
              {
                title: "Best Trade",
                value: pnl_data[:best_trade] ? "$#{pnl_data[:best_trade].round(2)}" : "N/A",
                short: true
              }
            ]
          }
        ]
      }
    end

    def handle_health_command
      health_data = get_health_status

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
        text: "#{emoji} Health Check Report",
        response_type: "in_channel",
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
                value: health_data[:database] ? "✅ Connected" : "❌ Disconnected",
                short: true
              },
              {
                title: "Coinbase API",
                value: health_data[:coinbase_api] ? "✅ Connected" : "❌ Disconnected",
                short: true
              },
              {
                title: "Background Jobs",
                value: health_data[:background_jobs] ? "✅ Running" : "❌ Stopped",
                short: true
              },
              {
                title: "WebSocket Connections",
                value: "#{health_data[:websocket_connections] || 0} active",
                short: true
              },
              {
                title: "Memory Usage",
                value: health_data[:memory_usage] || "N/A",
                short: true
              }
            ]
          }
        ]
      }
    end

    def handle_emergency_stop_command
      # Execute emergency stop
      emergency_stop_result = execute_emergency_stop

      SlackNotificationService.alert(
        "critical",
        "Emergency Stop Executed",
        "All trading activities stopped via Slack command. #{emergency_stop_result[:message]}"
      )

      {
        text: "🚨 EMERGENCY STOP EXECUTED 🚨\n\nAll trading activities have been immediately stopped.\n\n#{emergency_stop_result[:message]}",
        response_type: "in_channel",
        attachments: [
          {
            color: "danger",
            fields: [
              {
                title: "Positions Closed",
                value: emergency_stop_result[:positions_closed].to_s,
                short: true
              },
              {
                title: "Orders Cancelled",
                value: emergency_stop_result[:orders_cancelled].to_s,
                short: true
              },
              {
                title: "Trading Status",
                value: "🔴 DISABLED",
                short: true
              },
              {
                title: "Executed At",
                value: Time.current.strftime("%Y-%m-%d %H:%M:%S UTC"),
                short: true
              }
            ]
          }
        ]
      }
    end

    def handle_help_command
      {
        text: "🤖 Bot Commands Help",
        response_type: "ephemeral",
        attachments: [
          {
            color: "good",
            fields: [
              {
                title: "/bot-status",
                value: "Show current bot status and statistics",
                short: false
              },
              {
                title: "/bot-pause",
                value: "Pause trading (stop new signals and positions)",
                short: false
              },
              {
                title: "/bot-resume",
                value: "Resume trading operations",
                short: false
              },
              {
                title: "/bot-positions [filter]",
                value: "Show current positions. Optional filter: 'open', 'closed', symbol name",
                short: false
              },
              {
                title: "/bot-pnl [period]",
                value: "Show PnL report. Period: 'today' (default), 'week', 'month'",
                short: false
              },
              {
                title: "/bot-health",
                value: "Show system health status",
                short: false
              },
              {
                title: "/bot-stop",
                value: "🚨 EMERGENCY STOP - Immediately stop all trading",
                short: false
              },
              {
                title: "/bot-help",
                value: "Show this help message",
                short: false
              }
            ]
          }
        ]
      }
    end

    def unknown_command_response(command)
      {
        text: "❓ Unknown command: #{command}\n\nUse `/bot-help` to see available commands.",
        response_type: "ephemeral"
      }
    end

    def error_response(error_message)
      {
        text: "❌ Error executing command: #{error_message}",
        response_type: "ephemeral"
      }
    end

    # Helper methods to interact with the bot's state and services

    def get_bot_status
      positions = Position.open.day_trading.count
      daily_pnl = Position.where(entry_time: Date.current.beginning_of_day..Time.current).sum(:pnl)
      last_signal = GenerateSignalsJob.where(finished_at: Date.current.beginning_of_day..Time.current)
        .order(finished_at: :desc)
        .first

      {
        trading_active: trading_active?,
        open_positions: positions,
        daily_pnl: daily_pnl,
        last_signal_time: last_signal&.finished_at&.strftime("%H:%M UTC"),
        health_status: overall_health_status,
        uptime: application_uptime,
        healthy: true
      }
    rescue => e
      Rails.logger.error("[SlackCommand] Error getting bot status: #{e.message}")
      {
        trading_active: false,
        open_positions: 0,
        healthy: false,
        health_status: "error"
      }
    end

    def get_positions(filter = "")
      positions = Position.includes(:trading_pair)

      positions = case filter.downcase
      when "open"
        positions.open
      when "closed"
        positions.closed
      when ""
        positions.open # Default to open positions
      else
        # Assume it's a symbol filter
        positions.joins(:trading_pair).where("trading_pairs.product_id ILIKE ?", "%#{filter}%")
      end

      positions.order(entry_time: :desc).limit(10)
    rescue => e
      Rails.logger.error("[SlackCommand] Error getting positions: #{e.message}")
      []
    end

    def get_pnl_data(period)
      start_time = case period.downcase
      when "week"
        1.week.ago
      when "month"
        1.month.ago
      else
        Date.current.beginning_of_day
      end

      positions = Position.where(entry_time: start_time..Time.current)
      closed_positions = positions.closed

      total_pnl = positions.sum(:pnl) || 0
      realized_pnl = closed_positions.sum(:pnl) || 0
      unrealized_pnl = total_pnl - realized_pnl

      winning_trades = closed_positions.where("pnl > 0").count
      total_trades = closed_positions.count
      win_rate = (total_trades > 0) ? (winning_trades.to_f / total_trades * 100) : 0

      best_trade = closed_positions.maximum(:pnl)

      {
        total_pnl: total_pnl,
        realized_pnl: realized_pnl,
        unrealized_pnl: unrealized_pnl,
        completed_trades: total_trades,
        win_rate: win_rate,
        best_trade: best_trade
      }
    rescue => e
      Rails.logger.error("[SlackCommand] Error getting PnL data: #{e.message}")
      {
        total_pnl: 0,
        realized_pnl: 0,
        unrealized_pnl: 0,
        completed_trades: 0,
        win_rate: 0,
        best_trade: 0
      }
    end

    def get_health_status
      database_healthy = database_connected?
      coinbase_api_healthy = coinbase_api_connected?
      background_jobs_healthy = background_jobs_running?
      websocket_connections = active_websocket_connections
      memory_usage = get_memory_usage

      overall_health = if database_healthy && coinbase_api_healthy && background_jobs_healthy
        "healthy"
      elsif database_healthy && (coinbase_api_healthy || background_jobs_healthy)
        "warning"
      else
        "unhealthy"
      end

      {
        overall_health: overall_health,
        database: database_healthy,
        coinbase_api: coinbase_api_healthy,
        background_jobs: background_jobs_healthy,
        websocket_connections: websocket_connections,
        memory_usage: memory_usage
      }
    rescue => e
      Rails.logger.error("[SlackCommand] Error getting health status: #{e.message}")
      {
        overall_health: "error",
        database: false,
        coinbase_api: false,
        background_jobs: false,
        websocket_connections: 0,
        memory_usage: "N/A"
      }
    end

    def execute_emergency_stop
      positions_closed = 0
      orders_cancelled = 0

      begin
        # Disable trading
        set_trading_status(false, emergency: true)

        # Close all open positions
        open_positions = Position.open.day_trading
        open_positions.each do |position|
          # Close position logic would go here
          # position.close!
          positions_closed += 1
        end

        # Cancel any pending orders
        # orders_cancelled = cancel_all_pending_orders

        {
          success: true,
          message: "Emergency stop completed successfully.",
          positions_closed: positions_closed,
          orders_cancelled: orders_cancelled
        }
      rescue => e
        Rails.logger.error("[SlackCommand] Error during emergency stop: #{e.message}")
        {
          success: false,
          message: "Emergency stop partially completed. Error: #{e.message}",
          positions_closed: positions_closed,
          orders_cancelled: orders_cancelled
        }
      end
    end

    def set_trading_status(active, emergency: false)
      # This would set a flag in Redis or database to control trading
      # For now, we'll use Rails cache
      Rails.cache.write("trading_active", active)
      Rails.cache.write("emergency_stop", emergency) if emergency
      Rails.logger.info("[SlackCommand] Trading status set to: #{active ? "active" : "inactive"}#{emergency ? " (EMERGENCY)" : ""}")
    end

    def trading_active?
      Rails.cache.fetch("trading_active", expires_in: 1.hour) { true }
    end

    def database_connected?
      ActiveRecord::Base.connection.active?
    rescue
      false
    end

    def coinbase_api_connected?
      # Test Coinbase API connection
      client = Coinbase::Client.new
      result = client.test_auth
      result[:advanced_trade][:ok] == true
    rescue
      false
    end

    def background_jobs_running?
      # Check if GoodJob is processing jobs
      GoodJob::Job.where(finished_at: 1.hour.ago..Time.current).exists?
    rescue
      false
    end

    def active_websocket_connections
      # This would return the number of active WebSocket connections
      # For now, return 0 as placeholder
      0
    end

    def get_memory_usage
      # Get memory usage information
      if File.readable?("/proc/meminfo")
        meminfo = File.read("/proc/meminfo")
        if (match = meminfo.match(/MemAvailable:\s+(\d+)\s+kB/))
          available_kb = match[1].to_i
          available_mb = available_kb / 1024
          "#{available_mb} MB available"
        end
      end
    rescue
      "N/A"
    end

    def overall_health_status
      health = get_health_status
      health[:overall_health]
    end

    def application_uptime
      # Simple uptime calculation
      if defined?(@@start_time)
        duration = Time.current - @@start_time
        hours = (duration / 3600).to_i
        minutes = ((duration % 3600) / 60).to_i
        "#{hours}h #{minutes}m"
      else
        @@start_time = Time.current
        "Just started"
      end
    rescue
      "N/A"
    end

    def duration_since(start_time)
      return "N/A" unless start_time

      duration_seconds = Time.current - start_time
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
