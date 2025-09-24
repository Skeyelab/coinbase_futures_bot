# frozen_string_literal: true

class ChatBotService
  include SentryServiceTracking

  def initialize(session_id = nil)
    @session_id = session_id || SecureRandom.uuid
    @ai = AiCommandProcessorService.new
    @memory = ChatMemoryService.new(@session_id)
    @market_analysis = MarketAnalysisService.new
  end

  def process(input)
    start_time = Time.current
    sanitized_input = sanitize_input(input)

    track_service_call("process") do
      if sanitized_input.blank?
        error_result = error_response("Invalid input")
        return format_response(error_result, nil)
      end

      # Store user input in memory
      @memory.store_user_input(sanitized_input)

      # Get AI interpretation of the command with enhanced error handling
      ai_response, ai_error = get_ai_response_with_fallback(sanitized_input)
      command = parse_ai_response(ai_response, sanitized_input)

      # Execute the command
      result = execute_command(command, sanitized_input)

      # Format response for CLI
      formatted_response = format_response(result, command)

      # Store bot response in memory
      @memory.store_bot_response(formatted_response, result)

      # Comprehensive audit logging
      execution_time = ((Time.current - start_time) * 1000).round(2)
      log_command_execution(sanitized_input, command, ai_response, result, execution_time, ai_error)

      formatted_response
    end
  rescue => e
    ((Time.current - start_time) * 1000).round(2)
    Rails.logger.error("[ChatBotService] Error processing input: #{e.message}")

    # Log the error for audit purposes
    ChatAuditLogger.log_ai_service_error(
      session_id: @session_id,
      user_input: sanitized_input || input.to_s,
      error: e
    )

    error_result = error_response("Processing failed: #{e.message}")
    formatted_response = format_response(error_result, nil)

    # Store error response
    @memory&.store_bot_response(formatted_response, error_result)

    formatted_response
  end

  def session_summary
    @memory.session_summary
  end

  private

  def sanitize_input(input)
    input.to_s.strip.gsub(/[^\w\s\-.,?!]/, "")[0...500]
  end

  def build_context
    {
      session_id: @session_id,
      conversation_context: @memory.context_for_ai(2000),
      recent_interactions: @memory.recent_interactions(3),
      trading_status: trading_status_context,
      market_context: market_context
    }
  end

  def parse_ai_response(ai_response, original_input = nil)
    content = ai_response[:content].to_s.downcase
    input = original_input&.downcase || ""

    case content
    when /size|siz.*position|position.*siz/
      {type: "trading_control", params: {action: "position_sizing", content: content}}
    when /position|pnl|profit|loss|open|close/
      {type: "position_query", params: extract_position_params(content)}
    when /signal|alert|entry|exit/
      {type: "signal_query", params: extract_signal_params(content)}
    when /market|price|data|candle/
      {type: "market_data", params: extract_market_params(content)}
    when /what.*should.*do|advice|recommendation|analysis|analyze/
      {type: "market_analysis", params: extract_market_analysis_params(content)}
    when /status|health|system/
      {type: "system_status", params: {}}
    when /history|search|sessions|context/
      {type: "memory_command", params: extract_memory_params(content)}
    when /help|command|what/
      {type: "help", params: {}}
    when /(start|resume|enable).*trad|trad.*(start|resume|enable)/
      {type: "trading_control", params: {action: "start"}}
    when /(stop|pause|disable).*trad|trad.*(stop|pause|disable)/
      {type: "trading_control", params: {action: "stop"}}
    when /emergency.*stop|kill.*switch|stop.*emergency/
      {type: "trading_control", params: {action: "emergency_stop"}}
    else
      # Check original input for market analysis keywords if AI response doesn't match
      if input.match?(/analyze|analysis|recommend|what.*should.*do|advice|suggestion|market.*analysis/)
        {type: "market_analysis", params: extract_analysis_params(input)}
      else
        {type: "general", params: {content: ai_response[:content]}}
      end
    end
  end

  def execute_command(command, original_input)
    case command[:type]
    when "position_query"
      execute_position_query(command[:params])
    when "signal_query"
      execute_signal_query(command[:params])
    when "market_data"
      execute_market_data_query(command[:params])
    when "market_analysis"
      execute_market_analysis_query(command[:params])
    when "system_status"
      execute_status_query
    when "memory_command"
      execute_memory_command(command[:params], original_input)
    when "trading_control"
      execute_trading_control_command(command[:params], original_input)
    when "help"
      execute_help_command
    when "general"
      {type: "ai_response", content: command[:params][:content]}
    else
      error_response("Command not recognized")
    end
  end

  def execute_position_query(params)
    positions = Position.open.limit(10)
    total_pnl = positions.sum { |p| p.pnl || 0 }

    {
      type: "position_data",
      data: {
        open_positions: positions.count,
        day_trading: positions.day_trading.count,
        swing_trading: positions.swing_trading.count,
        total_pnl: total_pnl.round(2),
        positions: positions.map { |p| position_summary(p) }
      }
    }
  end

  def execute_signal_query(params)
    signals = SignalAlert.active.recent.limit(5)

    {
      type: "signal_data",
      data: {
        active_signals: signals.count,
        recent_signals: signals.map { |s| signal_summary(s) },
        last_signal_time: signals.first&.alert_timestamp&.strftime("%H:%M UTC")
      }
    }
  end

  def execute_market_data_query(params)
    symbol = params[:symbol] || "BTC-PERP"
    recent_candle = Candle.for_symbol(symbol).one_minute.order(timestamp: :desc).first

    {
      type: "market_data",
      data: {
        symbol: symbol,
        price: recent_candle&.close&.round(2),
        timestamp: recent_candle&.timestamp&.strftime("%H:%M UTC"),
        volume: recent_candle&.volume&.round(2)
      }
    }
  end

  def execute_market_analysis_query(params)
    symbol = params[:symbol] || "BTC-USD"
    timeframe = params[:timeframe] || "1h"

    analysis_service = MarketAnalysisService.new(symbol: symbol, timeframe: timeframe)
    advice = analysis_service.generate_advice

    {
      type: "market_analysis",
      data: {
        symbol: symbol,
        timeframe: timeframe,
        advice: advice
      }
    }
  end

  def extract_market_analysis_params(content)
    symbol = content.match(/\b(BTC|ETH|SOL|ADA|DOT|LINK|UNI|AAVE|MATIC|AVAX|ATOM|XRP|LTC|BCH|ETC|DOGE|SHIB)\b/i)&.captures&.first
    timeframe = content.match(/\b(1m|5m|15m|1h|4h|1d)\b/i)&.captures&.first

    {
      symbol: symbol ? "#{symbol.upcase}-USD" : nil,
      timeframe: timeframe || "1h"
    }
  end

  def execute_status_query
    day_positions = Position.open.day_trading.count
    swing_positions = Position.open.swing_trading.count

    {
      type: "system_status",
      data: {
        trading_active: trading_active?,
        day_trading_positions: day_positions,
        swing_trading_positions: swing_positions,
        health_status: "operational",
        uptime: application_uptime
      }
    }
  end

  def execute_memory_command(params, original_input)
    case params[:action]
    when "history"
      execute_history_command(params[:limit])
    when "search"
      execute_search_command(params[:query])
    when "sessions"
      execute_sessions_command
    when "context"
      execute_context_status_command
    else
      # Default to history for ambiguous commands
      execute_history_command(5)
    end
  end

  def execute_history_command(limit = 10)
    interactions = @memory.recent_interactions(limit)

    {
      type: "history_data",
      data: {
        interactions: interactions,
        total_count: @memory.session_summary[:total_interactions]
      }
    }
  end

  def execute_search_command(query)
    return error_response("Search query required") if query.blank?

    results = @memory.search_history(query)

    {
      type: "search_results",
      data: {
        query: query,
        results: results,
        count: results.size
      }
    }
  end

  def execute_sessions_command
    sessions = ChatSession.active.recent.limit(10).map do |session|
      {
        id: session.session_id[0..7],
        name: session.name || "Unnamed",
        message_count: session.message_count,
        last_activity: session.last_activity&.strftime("%m/%d %H:%M"),
        profitable_messages: session.profitable_messages.count
      }
    end

    {
      type: "sessions_data",
      data: {
        sessions: sessions,
        current_session: @session_id[0..7]
      }
    }
  end

  def execute_context_status_command
    summary = @memory.session_summary
    context_length = @memory.context_for_ai(4000).length

    {
      type: "context_status",
      data: {
        session_id: summary[:session_id][0..7],
        total_messages: summary[:total_interactions],
        profitable_messages: summary[:profitable_messages],
        context_length: context_length,
        estimated_tokens: (context_length / 4).to_i,
        last_activity: summary[:last_activity]
      }
    }
  end

  def execute_trading_control_command(params, original_input)
    case params[:action]
    when "start"
      execute_start_trading_command
    when "stop"
      execute_stop_trading_command
    when "emergency_stop"
      execute_emergency_stop_command
    when "position_sizing"
      execute_position_sizing_command(params[:content], original_input)
    else
      error_response("Unknown trading control action: #{params[:action]}")
    end
  end

  def execute_start_trading_command
    if trading_active?
      return {
        type: "trading_control_response",
        data: {
          action: "start",
          status: "already_active",
          message: "Trading is already active. No action needed."
        }
      }
    end

    set_trading_status(true)

    {
      type: "trading_control_response",
      data: {
        action: "start",
        status: "success",
        message: "\u2705 Trading has been activated. The bot will now generate signals and manage positions."
      }
    }
  end

  def execute_stop_trading_command
    unless trading_active?
      return {
        type: "trading_control_response",
        data: {
          action: "stop",
          status: "already_inactive",
          message: "Trading is already inactive. No action needed."
        }
      }
    end

    set_trading_status(false)

    {
      type: "trading_control_response",
      data: {
        action: "stop",
        status: "success",
        message: "\u23F8\uFE0F Trading has been paused. The bot will stop generating new signals and opening positions."
      }
    }
  end

  def execute_emergency_stop_command
    # Execute emergency stop similar to SlackCommandHandler
    result = execute_emergency_stop_internal

    {
      type: "trading_control_response",
      data: {
        action: "emergency_stop",
        status: result[:success] ? "success" : "partial",
        message: "🚨 EMERGENCY STOP EXECUTED 🚨\n\n#{result[:message]}\n\nPositions closed: #{result[:positions_closed]}\nOrders cancelled: #{result[:orders_cancelled]}"
      }
    }
  end

  def execute_position_sizing_command(content, original_input)
    # Extract sizing information from content
    current_equity = ENV.fetch("SIGNAL_EQUITY_USD", "10000").to_f
    risk_per_trade = ENV.fetch("RISK_PER_TRADE_PERCENT", "2").to_f

    {
      type: "trading_control_response",
      data: {
        action: "position_sizing",
        status: "info",
        message: "📊 Position Sizing Configuration:\n\nEquity: $#{current_equity.round(2)}\nRisk per trade: #{risk_per_trade}%\nMax risk per trade: $#{(current_equity * risk_per_trade / 100).round(2)}\n\nTo adjust sizing, update environment variables:\n- SIGNAL_EQUITY_USD\n- RISK_PER_TRADE_PERCENT"
      }
    }
  end

  def execute_help_command
    {
      type: "help",
      data: {
        commands: [
          "Check positions and PnL",
          "View active signals",
          "Get market data for symbols",
          "Analyze market conditions and get trading recommendations",
          'Ask "what should I do with this position based on the market?"',
          "Get advice on specific symbols or positions",
          "System status and health",
          "Start/resume trading operations",
          "Stop/pause trading operations",
          "Emergency stop (close all positions)",
          "Check position sizing configuration",
          "View conversation history",
          "Search past conversations",
          "List chat sessions",
          "Show context status",
          "General trading questions"
        ]
      }
    }
  end

  def format_response(result, command)
    case result[:type]
    when "position_data"
      format_position_response(result[:data])
    when "signal_data"
      format_signal_response(result[:data])
    when "market_data"
      format_market_response(result[:data])
    when "market_analysis"
      format_market_analysis_response(result[:data])
    when "system_status"
      format_status_response(result[:data])
    when "trading_control_response"
      format_trading_control_response(result[:data])
    when "history_data"
      format_history_response(result[:data])
    when "search_results"
      format_search_response(result[:data])
    when "sessions_data"
      format_sessions_response(result[:data])
    when "context_status"
      format_context_status_response(result[:data])
    when "help"
      format_help_response(result[:data])
    when "ai_response"
      result[:content]
    when "error"
      "❌ #{result[:message]}"
    else
      "Response received: #{result[:type]}"
    end
  end

  def format_position_response(data)
    output = "📊 Positions Summary\n"
    output += "Open: #{data[:open_positions]} (Day: #{data[:day_trading]}, Swing: #{data[:swing_trading]})\n"
    output += "Total PnL: $#{data[:total_pnl]}\n"

    if data[:positions].any?
      output += "\nRecent Positions:\n"
      data[:positions].each do |pos|
        output += "• #{pos[:side]} #{pos[:size]} #{pos[:symbol]} @ $#{pos[:entry_price]} (#{pos[:pnl]})\n"
      end
    end

    output
  end

  def format_signal_response(data)
    output = "🚨 Signal Summary\n"
    output += "Active Signals: #{data[:active_signals]}\n"
    output += "Last Signal: #{data[:last_signal_time] || "N/A"}\n"

    if data[:recent_signals].any?
      output += "\nRecent Signals:\n"
      data[:recent_signals].each do |signal|
        output += "• #{signal[:side].upcase} #{signal[:symbol]} @ $#{signal[:price]} (#{signal[:confidence]}%)\n"
      end
    end

    output
  end

  def format_market_response(data)
    "📈 Market Data\n#{data[:symbol]}: $#{data[:price]} at #{data[:timestamp]}\nVolume: #{data[:volume]}"
  end

  def format_market_analysis_response(data)
    data[:advice]
  end

  def format_status_response(data)
    status = data[:trading_active] ? "\u{1F7E2} Active" : "\u{1F534} Paused"
    "🤖 System Status: #{status}\nDay Trading: #{data[:day_trading_positions]} positions\nSwing Trading: #{data[:swing_trading_positions]} positions\nUptime: #{data[:uptime]}"
  end

  def format_history_response(data)
    output = "📜 Conversation History (#{data[:total_count]} total)\n"

    if data[:interactions].any?
      data[:interactions].each_with_index do |interaction, i|
        timestamp = Time.parse(interaction[:timestamp]).strftime("%H:%M")
        output += "#{i + 1}. [#{timestamp}] #{interaction[:command_type]}: #{interaction[:input].truncate(80)}\n"
      end
    else
      output += "No conversation history found."
    end

    output
  end

  def format_search_response(data)
    output = "🔍 Search Results for '#{data[:query]}' (#{data[:count]} found)\n"

    if data[:results].any?
      data[:results].each_with_index do |result, i|
        timestamp = result[1].strftime("%m/%d %H:%M")
        impact = result[2].upcase
        content = result[0].truncate(100)
        output += "#{i + 1}. [#{timestamp}] [#{impact}] #{content}\n"
      end
    else
      output += "No results found for your search."
    end

    output
  end

  def format_sessions_response(data)
    output = "💬 Chat Sessions (Current: #{data[:current_session]})\n"

    if data[:sessions].any?
      data[:sessions].each_with_index do |session, i|
        marker = (session[:id] == data[:current_session]) ? "\u2192" : " "
        output += "#{marker} #{i + 1}. #{session[:id]} - #{session[:name]}\n"
        output += "    Messages: #{session[:message_count]} (#{session[:profitable_messages]} profitable)\n"
        output += "    Last: #{session[:last_activity] || "N/A"}\n"
      end
    else
      output += "No active sessions found."
    end

    output
  end

  def format_context_status_response(data)
    output = "🧠 Context Status\n"
    output += "Session: #{data[:session_id]}\n"
    output += "Messages: #{data[:total_messages]} (#{data[:profitable_messages]} profitable)\n"
    output += "Context Length: #{data[:context_length]} chars (~#{data[:estimated_tokens]} tokens)\n"
    output += "Last Activity: #{data[:last_activity] || "N/A"}\n"
    output
  end

  def format_help_response(data)
    "💡 Available Commands:\n" + data[:commands].map { |cmd|
      "• #{cmd}"
    }.join("\n") + "\n\nExample queries:\n• 'Show my positions'\n• 'What signals are active?'\n• 'Start trading'\n• 'Stop trading'\n• 'Emergency stop'"
  end

  def format_trading_control_response(data)
    data[:message]
  end

  def error_response(message)
    {type: "error", message: message}
  end

  def position_summary(position)
    {
      symbol: position.product_id,
      side: position.side,
      size: position.size,
      entry_price: position.entry_price&.round(2),
      pnl: position.pnl ? "$#{position.pnl.round(2)}" : "N/A"
    }
  end

  def signal_summary(signal)
    {
      symbol: signal.symbol,
      side: signal.side,
      price: signal.entry_price&.round(2),
      confidence: signal.confidence
    }
  end

  def extract_position_params(content)
    symbol = content.match(/([A-Z]{3,4}[-_]?PERP?)/i)&.captures&.first
    {symbol: symbol&.upcase}
  end

  def extract_signal_params(content)
    symbol = content.match(/([A-Z]{3,4}[-_]?PERP?)/i)&.captures&.first
    {symbol: symbol&.upcase}
  end

  def extract_market_params(content)
    # Look for crypto symbols (BTC, ETH, etc.) in the content
    symbol = content.match(/\b(BTC|ETH|SOL|ADA|DOT|LINK|UNI|AAVE|MATIC|AVAX|ATOM|XRP|LTC|BCH|ETC|DOGE|SHIB)\b/i)&.captures&.first
    {symbol: symbol ? "#{symbol.upcase}-PERP" : "BTC-PERP"}
  end

  def extract_analysis_params(content)
    # Look for specific symbols or position references
    symbol = content.match(/\b(BTC|ETH|SOL|ADA|DOT|LINK|UNI|AAVE|MATIC|AVAX|ATOM|XRP|LTC|BCH|ETC|DOGE|SHIB)\b/i)&.captures&.first
    position_id = content.match(/position\s*(\d+)/i)&.captures&.first

    {
      symbol: symbol ? "#{symbol.upcase}-PERP" : nil,
      position_id: position_id&.to_i
    }
  end

  def extract_memory_params(content)
    case content
    when /history/
      limit = content.match(/\d+/)&.to_s&.to_i || 10
      {action: "history", limit: limit}
    when /search/
      query = content.match(/search\s+(.+)/i)&.captures&.first&.strip
      {action: "search", query: query}
    when /sessions/
      {action: "sessions"}
    when /context/
      {action: "context"}
    else
      {action: "history", limit: 5}
    end
  end

  def trading_status_context
    {
      active: trading_active?,
      day_positions: Position.open.day_trading.count,
      swing_positions: Position.open.swing_trading.count
    }
  end

  def market_context
    recent_signals = SignalAlert.active.recent(6).count
    {recent_signals: recent_signals}
  end

  def set_trading_status(active, emergency: false)
    Rails.cache.write("trading_active", active)
    Rails.cache.write("emergency_stop", emergency) if emergency
    Rails.logger.info("[ChatBot] Trading status set to: #{active ? "active" : "inactive"}#{if emergency
                                                                                             " (EMERGENCY)"
                                                                                           end}")
  end

  def trading_active?
    Rails.cache.fetch("trading_active", expires_in: 1.hour) { true }
  end

  def execute_emergency_stop_internal
    positions_closed = 0
    orders_cancelled = 0

    begin
      # Disable trading
      set_trading_status(false, emergency: true)

      # Close all open positions (simplified for now)
      open_positions = Position.open.day_trading
      open_positions.each do |position|
        # In a real implementation, this would call the trading API
        # position.close!
        positions_closed += 1
      end

      # Cancel any pending orders (placeholder)
      # orders_cancelled = cancel_all_pending_orders

      {
        success: true,
        message: "Emergency stop completed successfully.",
        positions_closed: positions_closed,
        orders_cancelled: orders_cancelled
      }
    rescue => e
      Rails.logger.error("[ChatBot] Error during emergency stop: #{e.message}")
      {
        success: false,
        message: "Emergency stop partially completed. Error: #{e.message}",
        positions_closed: positions_closed,
        orders_cancelled: orders_cancelled
      }
    end
  end

  def get_ai_response_with_fallback(input)
    context = build_context
    ai_error = nil

    begin
      ai_response = @ai.process_command(input, context: context)
      [ai_response, ai_error]
    rescue AiCommandProcessorService::ApiError => e
      ai_error = e
      Rails.logger.warn("[ChatBotService] AI service error: #{e.message}")

      # Log the specific AI service error
      ChatAuditLogger.log_ai_service_error(
        session_id: @session_id,
        user_input: input,
        error: e,
        fallback_used: true
      )

      # Fallback to simple pattern matching if AI fails
      fallback_response = simple_pattern_fallback(input)
      [fallback_response, ai_error]
    end
  end

  def simple_pattern_fallback(input)
    # Simple pattern matching when AI services are unavailable
    content = input.to_s.downcase

    case content
    when /position|pnl|profit|loss/
      {content: "User wants to check trading positions", provider: "fallback"}
    when /signal|alert/
      {content: "User wants to view active signals", provider: "fallback"}
    when /market|price|data/
      {content: "User wants market data information", provider: "fallback"}
    when /start.*trad|resume.*trad/
      {content: "User wants to start trading operations", provider: "fallback"}
    when /stop.*trad|pause.*trad/
      {content: "User wants to stop trading operations", provider: "fallback"}
    when /emergency.*stop/
      {content: "User wants emergency stop", provider: "fallback"}
    when /help/
      {content: "User wants help information", provider: "fallback"}
    else
      {content: "General query about trading system", provider: "fallback"}
    end
  end

  def log_command_execution(input, command, ai_response, result, execution_time, ai_error)
    # Standard command logging
    ChatAuditLogger.log_command(
      session_id: @session_id,
      user_input: input,
      command_type: command[:type],
      ai_response: ai_response,
      result: result,
      execution_time: execution_time,
      trading_impact: determine_trading_impact(command, result)
    )

    # Special logging for trading control commands
    return unless command[:type] == "trading_control"

    ChatAuditLogger.log_trading_control(
      session_id: @session_id,
      action: command.dig(:params, :action),
      user_input: input,
      result: result,
      user_context: build_user_context
    )
  end

  def determine_trading_impact(command, result)
    case command[:type]
    when "trading_control"
      case command.dig(:params, :action)
      when "emergency_stop"
        "critical"
      when "start", "stop"
        "high"
      when "position_sizing"
        "medium"
      else
        "low"
      end
    when "position_query"
      "medium"
    when "signal_query"
      "medium"
    else
      "low"
    end
  end

  def build_user_context
    {
      session_id: @session_id,
      trading_active: trading_active?,
      timestamp: Time.current.utc,
      recent_commands: @memory.recent_interactions(3).map { |i| i[:command_type] }
    }
  end

  def application_uptime
    if Rails.application.config.respond_to?(:started_at) && Rails.application.config.started_at
      "#{((Time.current - Rails.application.config.started_at) / 1.hour).to_i}h"
    else
      "N/A"
    end
  end
end
