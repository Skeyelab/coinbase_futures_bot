module ApplicationCable
  class Channel < ActionCable::Channel::Base
    # Global error handling for ActionCable channels
    rescue_from StandardError do |error|
      # Add channel context to Sentry
      Sentry.with_scope do |scope|
        scope.set_tag("channel", self.class.name)
        scope.set_tag("connection_id", connection.connection_identifier)
        scope.set_tag("error_type", "channel_error")

        scope.set_context("channel", {
          channel_class: self.class.name,
          params: params.to_h,
          subscriptions: stream_names,
          connection_id: connection.connection_identifier
        })

        Sentry.capture_exception(error)
      end

      # Log error details
      Rails.logger.error("[#{self.class.name}] Channel error: #{error.class} - #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))

      # Send error message to client
      transmit({
        type: "error",
        message: "Channel error occurred",
        timestamp: Time.current.utc.iso8601
      })
    end

    # Track channel subscription events
    def subscribed
      SentryHelper.add_breadcrumb(
        message: "ActionCable channel subscribed",
        category: "websocket",
        level: "info",
        data: {
          channel: self.class.name,
          params: params.to_h,
          connection_id: connection.connection_identifier
        }
      )

      super
    end

    # Track channel unsubscription events
    def unsubscribed
      SentryHelper.add_breadcrumb(
        message: "ActionCable channel unsubscribed",
        category: "websocket",
        level: "info",
        data: {
          channel: self.class.name,
          connection_id: connection.connection_identifier
        }
      )

      super
    end
  end
end
