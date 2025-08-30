module ApplicationCable
  class Connection < ActionCable::Connection::Base
    # Track connection events and errors
    def connect
      SentryHelper.add_breadcrumb(
        message: "ActionCable connection established",
        category: "websocket",
        level: "info",
        data: {
          connection_id: connection_identifier,
          origin: request.origin,
          user_agent: request.user_agent
        }
      )

      super
    rescue => e
      # Track connection failures
      Sentry.with_scope do |scope|
        scope.set_tag("connection_type", "actioncable")
        scope.set_tag("error_type", "connection_error")

        scope.set_context("connection", {
          origin: request.origin,
          user_agent: request.user_agent,
          headers: request.headers.to_h.slice("HTTP_ORIGIN", "HTTP_USER_AGENT", "HTTP_HOST")
        })

        Sentry.capture_exception(e)
      end

      raise
    end

    def disconnect
      SentryHelper.add_breadcrumb(
        message: "ActionCable connection disconnected",
        category: "websocket",
        level: "info",
        data: {
          connection_id: connection_identifier
        }
      )

      super
    end
  end
end
