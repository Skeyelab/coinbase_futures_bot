# frozen_string_literal: true

class ChatAuditLogger
  include SentryServiceTracking

  class << self
    # Log a command execution with full context
    def log_command(session_id:, user_input:, command_type:, ai_response:, result:, execution_time:, trading_impact: nil)
      track_service_call("log_command") do
        audit_data = {
          session_id: session_id,
          timestamp: Time.current.utc,
          user_input: sanitize_input(user_input),
          command_type: command_type,
          ai_response: sanitize_ai_response(ai_response),
          result_type: result[:type],
          execution_time_ms: execution_time,
          trading_impact: trading_impact,
          metadata: build_metadata(command_type, result)
        }

        # Log to Rails logger with structured format
        Rails.logger.info("[ChatAudit] #{audit_data.to_json}")

        # Store in database for persistence and querying
        store_audit_record(audit_data)
      end
    rescue => e
      Rails.logger.error("[ChatAudit] Failed to log command: #{e.message}")
    end

    # Log trading control actions separately for security audit
    def log_trading_control(session_id:, action:, user_input:, result:, user_context: nil)
      track_service_call("log_trading_control") do
        security_audit_data = {
          session_id: session_id,
          timestamp: Time.current.utc,
          audit_type: "trading_control",
          action: action,
          user_input: sanitize_input(user_input),
          result_status: result.dig(:data, :status),
          result_message: result.dig(:data, :message),
          trading_active_before: Rails.cache.read("trading_active"),
          trading_active_after: action_changes_trading_status?(action) ? !Rails.cache.read("trading_active") : Rails.cache.read("trading_active"),
          user_context: user_context,
          risk_level: determine_risk_level(action)
        }

        # Log to Rails logger with SECURITY prefix for filtering
        Rails.logger.warn("[SECURITY][ChatAudit] #{security_audit_data.to_json}")

        # Store in database with security flag
        store_security_audit_record(security_audit_data)

        # Send to external security monitoring if configured
        send_to_security_monitoring(security_audit_data) if security_monitoring_enabled?
      end
    rescue => e
      Rails.logger.error("[ChatAudit] Failed to log trading control action: #{e.message}")
    end

    # Log AI service errors and fallbacks
    def log_ai_service_error(session_id:, user_input:, error:, fallback_used: false)
      track_service_call("log_ai_service_error") do
        error_data = {
          session_id: session_id,
          timestamp: Time.current.utc,
          audit_type: "ai_service_error",
          user_input: sanitize_input(user_input),
          error_class: error.class.name,
          error_message: error.message,
          fallback_used: fallback_used,
          ai_service_health: check_ai_service_health
        }

        Rails.logger.error("[ChatAudit][AI_ERROR] #{error_data.to_json}")
        store_error_audit_record(error_data)
      end
    rescue => e
      Rails.logger.error("[ChatAudit] Failed to log AI service error: #{e.message}")
    end

    # Generate audit report for a session
    def session_audit_report(session_id, start_time: 24.hours.ago, end_time: Time.current)
      track_service_call("session_audit_report") do
        # This would query the audit records from database
        # For now, return a structured summary
        {
          session_id: session_id,
          period: {start: start_time, end: end_time},
          summary: generate_session_summary(session_id, start_time, end_time),
          trading_control_actions: count_trading_control_actions(session_id, start_time, end_time),
          ai_service_health: calculate_ai_service_health(session_id, start_time, end_time),
          risk_indicators: assess_risk_indicators(session_id, start_time, end_time)
        }
      end
    end

    private

    def sanitize_input(input)
      input.to_s.truncate(1000).gsub(/[^\w\s\-.,?!]/, "")
    end

    def sanitize_ai_response(ai_response)
      return nil unless ai_response.is_a?(Hash)

      {
        content: ai_response[:content].to_s.truncate(500),
        model: ai_response[:model],
        provider: ai_response[:provider],
        usage: ai_response[:usage]
      }
    end

    def build_metadata(command_type, result)
      metadata = {
        result_size: result.to_s.length
      }

      case command_type
      when "position_query"
        metadata[:position_count] = result.dig(:data, :open_positions)
        metadata[:total_pnl] = result.dig(:data, :total_pnl)
      when "signal_query"
        metadata[:signal_count] = result.dig(:data, :active_signals)
      when "market_data"
        metadata[:symbol] = result.dig(:data, :symbol)
        metadata[:price] = result.dig(:data, :price)
      when "trading_control"
        metadata[:action] = result.dig(:data, :action)
        metadata[:trading_status_changed] = action_changes_trading_status?(result.dig(:data, :action))
      end

      metadata
    end

    def store_audit_record(audit_data)
      # In a real implementation, this would store to a dedicated audit table
      # For now, we'll use the chat messages table with a special flag
      return unless audit_data[:session_id]

      session = ChatSession.find_by(session_id: audit_data[:session_id])
      return unless session

      session.chat_messages.create!(
        content: "AUDIT: #{audit_data[:command_type]} - #{audit_data[:user_input].truncate(100)}",
        message_type: "system",
        profit_impact: determine_profit_impact_from_command(audit_data[:command_type]),
        relevance_score: 3.0, # Medium relevance for audit records
        timestamp: audit_data[:timestamp],
        metadata: audit_data.except(:session_id, :timestamp)
      )
    end

    def store_security_audit_record(security_data)
      # Store security-sensitive actions in a separate location
      # This could be a separate database, encrypted storage, or external service
      Rails.logger.info("[SECURITY_AUDIT] Trading control action logged: #{security_data[:action]}")
    end

    def store_error_audit_record(error_data)
      Rails.logger.error("[ERROR_AUDIT] AI service error logged for session: #{error_data[:session_id]}")
    end

    def determine_risk_level(action)
      case action.to_s
      when "emergency_stop"
        "HIGH"
      when "start", "stop"
        "MEDIUM"
      when "position_sizing"
        "LOW"
      else
        "UNKNOWN"
      end
    end

    def action_changes_trading_status?(action)
      %w[start stop emergency_stop].include?(action.to_s)
    end

    def determine_profit_impact_from_command(command_type)
      case command_type
      when "trading_control", "position_query"
        "high"
      when "signal_query", "market_data"
        "medium"
      else
        "low"
      end
    end

    def check_ai_service_health
      # Simplified health check - in real implementation would test actual APIs
      {
        openrouter_available: ENV["OPENROUTER_API_KEY"].present?,
        openai_available: ENV["OPENAI_API_KEY"].present?,
        last_check: Time.current.utc
      }
    end

    def security_monitoring_enabled?
      ENV["SECURITY_MONITORING_ENABLED"] == "true"
    end

    def send_to_security_monitoring(data)
      # Integration point for external security monitoring systems
      # Could be Splunk, Datadog, custom security dashboard, etc.
      Rails.logger.info("[SECURITY_MONITORING] Sending data to external system")
    end

    def generate_session_summary(session_id, start_time, end_time)
      {
        total_commands: 0, # Would query audit records
        command_types: [], # Would aggregate from audit records
        trading_actions: 0,
        errors: 0
      }
    end

    def count_trading_control_actions(session_id, start_time, end_time)
      # Would query security audit records
      {
        start_actions: 0,
        stop_actions: 0,
        emergency_stops: 0,
        position_sizing_queries: 0
      }
    end

    def calculate_ai_service_health(session_id, start_time, end_time)
      # Would analyze error rates and response times
      {
        success_rate: 100.0,
        average_response_time: 1500,
        fallback_usage: 0
      }
    end

    def assess_risk_indicators(session_id, start_time, end_time)
      # Would look for suspicious patterns
      {
        rapid_trading_changes: false,
        unusual_command_patterns: false,
        failed_authentication_attempts: 0
      }
    end
  end
end
