# frozen_string_literal: true

class ChatBotService
  include SentryServiceTracking

  def initialize(session_id = nil)
    @session_id = session_id || SecureRandom.uuid
    @ai = AiCommandProcessorService.new
    @memory = ChatMemoryService.new(@session_id)
  end

  def process(input)
    track_service_call("process") do
      sanitized_input = sanitize_input(input)
      if sanitized_input.blank?
        error_result = error_response("Invalid input")
        return format_response(error_result, nil)
      end

      # Store user input in memory
      @memory.store_user_input(sanitized_input)

      # Get AI interpretation of the command
      ai_response = @ai.process_command(sanitized_input, context: build_context)
      command = parse_ai_response(ai_response)

      # Execute the command
      result = execute_command(command, sanitized_input)

      # Format response for CLI
      formatted_response = format_response(result, command)

      # Store bot response in memory
      @memory.store_bot_response(formatted_response, result)

      formatted_response
    end
  rescue => e
    Rails.logger.error("[ChatBotService] Error processing input: #{e.message}")
    error_result = error_response("Processing failed: #{e.message}")
    formatted_response = format_response(error_result, nil)

    # Store error response
    @memory.store_bot_response(formatted_response, error_result)

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

  def parse_ai_response(ai_response)
    content = ai_response[:content].to_s.downcase

    case content
    when /position|pnl|profit|loss|open|close/
      {type: "position_query", params: extract_position_params(content)}
    when /signal|alert|entry|exit/
      {type: "signal_query", params: extract_signal_params(content)}
    when /market|price|data|candle/
      {type: "market_data", params: extract_market_params(content)}
    when /status|health|system/
      {type: "system_status", params: {}}
    when /history|search|sessions|context/
      {type: "memory_command", params: extract_memory_params(content)}
    when /help|command|what/
      {type: "help", params: {}}
    else
      {type: "general", params: {content: ai_response[:content]}}
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
    when "system_status"
      execute_status_query
    when "memory_command"
      execute_memory_command(command[:params], original_input)
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

  def execute_help_command
    {
      type: "help",
      data: {
        commands: [
          "Check positions and PnL",
          "View active signals",
          "Get market data for symbols",
          "System status and health",
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
    when "system_status"
      format_status_response(result[:data])
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

  def format_status_response(data)
    status = data[:trading_active] ? "🟢 Active" : "🔴 Paused"
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
        marker = (session[:id] == data[:current_session]) ? "→" : " "
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
    "💡 Available Commands:\n" + data[:commands].map { |cmd| "• #{cmd}" }.join("\n")
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

  def trading_active?
    Rails.cache.fetch("trading_active", expires_in: 1.hour) { true }
  end

  def application_uptime
    if Rails.application.config.respond_to?(:started_at) && Rails.application.config.started_at
      "#{((Time.current - Rails.application.config.started_at) / 1.hour).to_i}h"
    else
      "N/A"
    end
  end
end
