# frozen_string_literal: true

# Concern for adding Sentry error tracking to service classes
module SentryServiceTracking
  extend ActiveSupport::Concern

  # Track service method calls with Sentry
  def track_service_call(operation, **context_data, &block)
    service_name = self.class.name.underscore.tr("/", "_")

    SentryHelper.add_breadcrumb(
      message: "Service operation started",
      category: "service",
      level: "info",
      data: {
        service: service_name,
        operation: operation
      }.merge(context_data)
    )

    start_time = Time.current
    result = yield
    duration = (Time.current - start_time) * 1000

    # Track successful operations
    SentryHelper.add_breadcrumb(
      message: "Service operation completed",
      category: "service",
      level: "info",
      data: {
        service: service_name,
        operation: operation,
        duration_ms: duration.round(2),
        success: true
      }.merge(context_data)
    )

    result
  rescue => e
    duration = (Time.current - start_time) * 1000

    # Enhanced error tracking for service failures
    Sentry.with_scope do |scope|
      scope.set_tag("service", service_name)
      scope.set_tag("operation", operation)
      scope.set_tag("error_type", "service_error")

      scope.set_context("service_call", {
        service: service_name,
        operation: operation,
        duration_ms: duration.round(2),
        context: context_data
      })

      Sentry.capture_exception(e)
    end

    raise
  end

  # Track external API calls with enhanced context
  def track_external_api_call(service_name, endpoint, operation, **context_data, &block)
    SentryHelper.add_breadcrumb(
      message: "External API call started",
      category: "api",
      level: "info",
      data: {
        external_service: service_name,
        endpoint: endpoint,
        operation: operation
      }.merge(context_data)
    )

    start_time = Time.current
    result = yield
    duration = (Time.current - start_time) * 1000

    # Track successful API calls
    SentryHelper.add_breadcrumb(
      message: "External API call completed",
      category: "api",
      level: "info",
      data: {
        external_service: service_name,
        endpoint: endpoint,
        operation: operation,
        duration_ms: duration.round(2),
        success: true
      }.merge(context_data)
    )

    result
  rescue Faraday::ClientError => e
    duration = (Time.current - start_time) * 1000

    # Track API client errors
    Sentry.with_scope do |scope|
      scope.set_tag("external_service", service_name)
      scope.set_tag("endpoint", endpoint)
      scope.set_tag("operation", operation)
      scope.set_tag("error_type", "api_client_error")

      scope.set_context("external_api_call", {
        service: service_name,
        endpoint: endpoint,
        operation: operation,
        duration_ms: duration.round(2),
        response_status: e.response&.dig(:status),
        response_body: e.response&.dig(:body)&.to_s&.[](0..500), # Truncate for safety
        context: context_data
      })

      Sentry.capture_exception(e)
    end

    raise
  rescue Net::HTTPError => e
    duration = (Time.current - start_time) * 1000

    # Track HTTP errors
    Sentry.with_scope do |scope|
      scope.set_tag("external_service", service_name)
      scope.set_tag("endpoint", endpoint)
      scope.set_tag("operation", operation)
      scope.set_tag("error_type", "http_error")

      scope.set_context("external_api_call", {
        service: service_name,
        endpoint: endpoint,
        operation: operation,
        duration_ms: duration.round(2),
        context: context_data
      })

      Sentry.capture_exception(e)
    end

    raise
  rescue => e
    duration = (Time.current - start_time) * 1000

    # Track unexpected errors
    Sentry.with_scope do |scope|
      scope.set_tag("external_service", service_name)
      scope.set_tag("endpoint", endpoint)
      scope.set_tag("operation", operation)
      scope.set_tag("error_type", "unexpected_api_error")

      scope.set_context("external_api_call", {
        service: service_name,
        endpoint: endpoint,
        operation: operation,
        duration_ms: duration.round(2),
        context: context_data
      })

      Sentry.capture_exception(e)
    end

    raise
  end

  # Track trading operations with enhanced context
  def track_trading_operation(operation, **context_data, &block)
    SentryHelper.add_breadcrumb(
      message: "Trading operation started",
      category: "trading",
      level: "info",
      data: {
        operation: operation,
        trading_mode: (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live"
      }.merge(context_data)
    )

    start_time = Time.current
    result = yield
    duration = (Time.current - start_time) * 1000

    # Track successful trading operations
    SentryHelper.add_breadcrumb(
      message: "Trading operation completed",
      category: "trading",
      level: "info",
      data: {
        operation: operation,
        duration_ms: duration.round(2),
        success: true,
        trading_mode: (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live"
      }.merge(context_data)
    )

    result
  rescue => e
    duration = (Time.current - start_time) * 1000

    # Track trading operation failures
    Sentry.with_scope do |scope|
      scope.set_tag("trading_operation", operation)
      scope.set_tag("error_type", "trading_error")
      scope.set_tag("critical", "true")
      scope.set_tag("trading_mode", (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live")

      scope.set_context("trading_operation", {
        operation: operation,
        duration_ms: duration.round(2),
        context: context_data
      })

      Sentry.capture_exception(e)
    end

    raise
  end
end
