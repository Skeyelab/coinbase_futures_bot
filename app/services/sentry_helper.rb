# frozen_string_literal: true

# Helper service for Sentry operations with correct API usage
class SentryHelper
  class << self
    # Add breadcrumb with correct API - accepts both hash and keyword arguments
    def add_breadcrumb(message_or_hash = nil, category: "general", level: "info", data: {}, **kwargs)
      return unless enabled?

      # Handle both hash-style and keyword arguments for backward compatibility
      breadcrumb_data = if message_or_hash.is_a?(Hash)
        message_or_hash
      else
        {
          message: message_or_hash || kwargs[:message],
          category: kwargs[:category] || category,
          level: kwargs[:level] || level,
          data: kwargs[:data] || data
        }
      end

      # Use the correct Sentry API
      breadcrumb = Sentry::Breadcrumb.new
      breadcrumb.message = breadcrumb_data[:message]
      breadcrumb.category = breadcrumb_data[:category]
      breadcrumb.level = breadcrumb_data[:level]
      breadcrumb.data = breadcrumb_data[:data] || {}
      breadcrumb.timestamp = Time.current.to_f

      Sentry.add_breadcrumb(breadcrumb)
    end

    # Capture exception with enhanced context
    def capture_exception(exception, **context)
      return unless enabled?

      Sentry.with_scope do |scope|
        context.each do |key, value|
          case key
          when :tags
            value.each { |tag_key, tag_value| scope.set_tag(tag_key, tag_value) }
          when :context
            value.each { |context_key, context_value| scope.set_context(context_key, context_value) }
          when :user
            scope.set_user(value)
          when :level
            scope.set_level(value)
          end
        end

        Sentry.capture_exception(exception)
      end
    end

    # Capture message with enhanced context
    def capture_message(message, level: "info", **context)
      return unless enabled?

      Sentry.with_scope do |scope|
        context.each do |key, value|
          case key
          when :tags
            value.each { |tag_key, tag_value| scope.set_tag(tag_key, tag_value) }
          when :context
            value.each { |context_key, context_value| scope.set_context(context_key, context_value) }
          when :user
            scope.set_user(value)
          end
        end

        Sentry.capture_message(message, level: level)
      end
    end

    # Track performance with transaction
    def track_performance(name, op = "custom", **context, &block)
      return yield unless enabled?

      Sentry.start_transaction(name: name, op: op) do |transaction|
        context.each do |key, value|
          transaction.set_data(key, value)
        end

        yield
      end
    end

    private

    def enabled?
      defined?(Sentry) && ENV["SENTRY_DSN"].present?
    end
  end
end
