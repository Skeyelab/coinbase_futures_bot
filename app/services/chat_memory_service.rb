# frozen_string_literal: true

class ChatMemoryService
  include SentryServiceTracking

  # Trading-related keywords for relevance scoring
  TRADING_KEYWORDS_REGEX = /position|signal|profit|loss|entry|exit|trade|market/i

  def initialize(session_id)
    @session_id = session_id
    @session = ChatSession.find_or_create_by_session_id(session_id)
  end

  def store(content, type, profit_impact = :unknown)
    track_service_call("store") do
      relevance_score = calculate_relevance_score(content, type, profit_impact)

      # Prune old messages first if we have too many (before adding new message)
      prune_old_messages if @session.chat_messages.count >= 200

      @session.chat_messages.create!(
        content: content.to_s.truncate(2000),
        message_type: type.to_s,
        profit_impact: profit_impact.to_s,
        relevance_score: relevance_score,
        timestamp: Time.current,
        metadata: {command_type: extract_command_type(content)}
      )

      # Update session activity
      @session.touch
    end
  end

  def store_user_input(input)
    profit_impact = determine_profit_impact(input)
    store(input, :user, profit_impact)
  end

  def store_bot_response(response, command_result = nil)
    profit_impact = determine_response_profit_impact(response, command_result)
    store(response, :bot, profit_impact)
  end

  def context_for_ai(max_tokens = 4000)
    # Get recent profitable messages with proper token management
    messages = @session.chat_messages.profitable.recent

    # Token estimation and truncation with proper limit
    context_parts = []
    estimated_tokens = 0

    messages.each do |msg|
      # Use more sophisticated token estimation
      msg_content = "#{msg.message_type}: #{msg.content}"
      msg_tokens = msg.estimated_tokens

      break if estimated_tokens + msg_tokens > max_tokens

      context_parts << msg_content
      estimated_tokens += msg_tokens
    end

    context_parts.reverse.join("\n")
  end

  def recent_interactions(limit = 5)
    @session.chat_messages.recent.limit(limit).pluck(:content, :message_type, :timestamp)
      .map { |content, type, time| {input: content, command_type: type, timestamp: time.iso8601} }
  end

  def search_history(query)
    @session.chat_messages
      .where("content ILIKE ?", "%#{query}%")
      .profitable
      .recent
      .limit(10)
      .pluck(:content, :timestamp, :profit_impact)
  end

  def session_summary
    {
      session_id: @session_id,
      total_interactions: @session.message_count,
      last_activity: @session.last_activity&.iso8601,
      profitable_messages: @session.profitable_messages.count,
      active: @session.active?
    }
  end

  def clear_session
    @session.chat_messages.destroy_all
  end

  def deactivate_session
    @session.deactivate!
  end

  private

  def calculate_relevance_score(content, type, profit_impact)
    # Simple profit-focused scoring
    base_score = case profit_impact.to_s
    when "high" then 5.0
    when "medium" then 3.0
    when "low" then 2.0
    else 1.0
    end

    # Boost for trading keywords
    base_score += 0.5 if content.match?(TRADING_KEYWORDS_REGEX)

    # Boost for successful commands
    base_score += 0.5 if type.to_s == "bot" && content.match?(/success|completed|executed/i)

    [base_score, 5.0].min
  end

  def determine_profit_impact(input)
    case input.downcase
    when /position|pnl|profit|loss|trade|signal|entry|exit/
      :high
    when /market|price|data|status/
      :medium
    when /help|what|how/
      :low
    else
      :unknown
    end
  end

  def determine_response_profit_impact(response, command_result)
    return :high if command_result&.dig(:type) == "position_data"
    return :medium if command_result&.dig(:type) == "signal_data"
    return :medium if command_result&.dig(:type) == "market_data"

    # Check response content for trading relevance
    if response.match?(TRADING_KEYWORDS_REGEX)
      :medium
    else
      :low
    end
  end

  def extract_command_type(content)
    case content.downcase
    when /position/ then "position_query"
    when /signal/ then "signal_query"
    when /market/ then "market_data"
    when /status/ then "system_status"
    when /help/ then "help"
    else "general"
    end
  end

  def prune_old_messages
    # Keep only top 100 messages by relevance and recency
    # This will be called when we have 201+ messages, so we keep 100 and add 1 new = 101 total
    keeper_ids = @session.chat_messages
      .order(relevance_score: :desc, timestamp: :desc)
      .limit(100)
      .pluck(:id)

    @session.chat_messages.where.not(id: keeper_ids).destroy_all
  end
end
