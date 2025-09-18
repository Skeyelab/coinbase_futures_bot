# frozen_string_literal: true

class ChatMemoryService
  include SentryServiceTracking

  def initialize(session_id)
    @session_id = session_id
    @cache_key = "chat_session:#{session_id}"
  end

  def store(input, result)
    track_service_call("store") do
      memory = load_memory
      memory[Time.current.to_i] = {
        input: input.to_s.truncate(200),
        command_type: result[:type],
        timestamp: Time.current.utc.iso8601
      }

      # Keep only last 50 interactions
      trimmed_memory = memory.to_a.last(50).to_h
      save_memory(trimmed_memory)
    end
  end

  def recent_interactions(limit = 5)
    load_memory.values.last(limit)
  end

  def interaction_count
    load_memory.size
  end

  def last_command_type
    load_memory.values.last&.dig(:command_type)
  end

  def clear_session
    Rails.cache.delete(@cache_key)
  end

  def session_summary
    memory = load_memory
    {
      session_id: @session_id,
      total_interactions: memory.size,
      last_activity: memory.values.last&.dig(:timestamp),
      command_types: memory.values.map { |v| v[:command_type] }.uniq
    }
  end

  private

  def load_memory
    Rails.cache.fetch(@cache_key, expires_in: 24.hours) { {} }
  end

  def save_memory(memory)
    Rails.cache.write(@cache_key, memory, expires_in: 24.hours)
  end
end
