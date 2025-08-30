class ApplicationController < ActionController::API
  # Global error handling with Sentry integration
  rescue_from StandardError do |error|
    # Add controller context to Sentry
    Sentry.with_scope do |scope|
      scope.set_tag("controller", controller_name)
      scope.set_tag("action", action_name)
      scope.set_tag("request_method", request.method)
      scope.set_tag("request_path", request.path)

      # Add request context
      scope.set_context("request", {
        url: request.url,
        method: request.method,
        headers: sanitized_headers,
        params: sanitized_params,
        remote_ip: request.remote_ip,
        user_agent: request.user_agent
      })

      # Add breadcrumb for controller action
      SentryHelper.add_breadcrumb(
        message: "Controller action started",
        category: "controller",
        level: "info",
        data: {
          controller: controller_name,
          action: action_name,
          method: request.method,
          path: request.path
        }
      )

      # Capture the exception
      Sentry.capture_exception(error)
    end

    # Log error details for local debugging
    Rails.logger.error("[#{controller_name}##{action_name}] Controller error: #{error.class} - #{error.message}")
    Rails.logger.error(error.backtrace.join("\n"))

    # Return appropriate error response
    render json: {
      error: "Internal server error",
      message: Rails.env.development? ? error.message : "Something went wrong"
    }, status: :internal_server_error
  end

  private

  # Sanitize headers to avoid sending sensitive data to Sentry
  def sanitized_headers
    headers = request.headers.to_h
    headers.except(
      "HTTP_AUTHORIZATION",
      "HTTP_COOKIE",
      "HTTP_X_API_KEY",
      "HTTP_X_AUTH_TOKEN"
    )
  end

  # Sanitize parameters to avoid sending sensitive data to Sentry
  def sanitized_params
    params.to_unsafe_h.except(
      "password",
      "token",
      "secret",
      "api_key",
      "private_key"
    )
  end
end
