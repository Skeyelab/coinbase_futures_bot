# frozen_string_literal: true

# Concern for adding Sentry error tracking to ActiveRecord models
module SentryTrackable
  extend ActiveSupport::Concern

  included do
    # Track validation failures
    after_validation :track_validation_errors, if: :errors_present?

    # Track save failures
    around_save :track_save_operation
    around_update :track_update_operation
    around_destroy :track_destroy_operation
  end

  private

  def errors_present?
    errors.any?
  end

  def track_validation_errors
    return unless errors.any?

    # Group errors by attribute for better organization
    error_summary = errors.group_by(&:attribute).transform_values do |attribute_errors|
      attribute_errors.map(&:message)
    end

    Sentry.with_scope do |scope|
      scope.set_tag("model", self.class.name)
      scope.set_tag("operation", "validation")
      scope.set_tag("error_type", "validation_error")

      scope.set_context("validation_errors", {
        model: self.class.name,
        record_id: id,
        error_count: errors.count,
        error_summary: error_summary,
        changed_attributes: changed_attributes.keys
      })

      Sentry.capture_message("Model validation failed", level: "warning")
    end
  end

  def track_save_operation
    operation_start = Time.current

    SentryHelper.add_breadcrumb(
      message: "Model save operation started",
      category: "model",
      level: "info",
      data: {
        model: self.class.name,
        record_id: id,
        new_record: new_record?
      }
    )

    result = yield

    duration = (Time.current - operation_start) * 1000

    # Track successful saves
    SentryHelper.add_breadcrumb(
      message: "Model save completed",
      category: "model",
      level: "info",
      data: {
        model: self.class.name,
        record_id: id,
        duration_ms: duration.round(2),
        success: result
      }
    )

    result
  rescue => e
    duration = (Time.current - operation_start) * 1000

    # Track save failures
    Sentry.with_scope do |scope|
      scope.set_tag("model", self.class.name)
      scope.set_tag("operation", "save")
      scope.set_tag("error_type", "save_error")

      scope.set_context("model_operation", {
        model: self.class.name,
        record_id: id,
        new_record: new_record?,
        duration_ms: duration.round(2),
        changed_attributes: changed_attributes.keys,
        validation_errors: errors.full_messages
      })

      Sentry.capture_exception(e)
    end

    raise
  end

  def track_update_operation
    operation_start = Time.current

    SentryHelper.add_breadcrumb(
      message: "Model update operation started",
      category: "model",
      level: "info",
      data: {
        model: self.class.name,
        record_id: id,
        changed_attributes: changed_attributes.keys
      }
    )

    result = yield

    duration = (Time.current - operation_start) * 1000

    # Track successful updates
    SentryHelper.add_breadcrumb(
      message: "Model update completed",
      category: "model",
      level: "info",
      data: {
        model: self.class.name,
        record_id: id,
        duration_ms: duration.round(2),
        success: result
      }
    )

    result
  rescue => e
    duration = (Time.current - operation_start) * 1000

    # Track update failures
    Sentry.with_scope do |scope|
      scope.set_tag("model", self.class.name)
      scope.set_tag("operation", "update")
      scope.set_tag("error_type", "update_error")

      scope.set_context("model_operation", {
        model: self.class.name,
        record_id: id,
        duration_ms: duration.round(2),
        changed_attributes: changed_attributes.keys,
        validation_errors: errors.full_messages
      })

      Sentry.capture_exception(e)
    end

    raise
  end

  def track_destroy_operation
    operation_start = Time.current
    record_info = {model: self.class.name, record_id: id}

    SentryHelper.add_breadcrumb(
      message: "Model destroy operation started",
      category: "model",
      level: "info",
      data: record_info
    )

    result = yield

    duration = (Time.current - operation_start) * 1000

    # Track successful destroys
    SentryHelper.add_breadcrumb(
      message: "Model destroy completed",
      category: "model",
      level: "info",
      data: record_info.merge(
        duration_ms: duration.round(2),
        success: result
      )
    )

    result
  rescue => e
    duration = (Time.current - operation_start) * 1000

    # Track destroy failures
    Sentry.with_scope do |scope|
      scope.set_tag("model", self.class.name)
      scope.set_tag("operation", "destroy")
      scope.set_tag("error_type", "destroy_error")

      scope.set_context("model_operation", record_info.merge(
        duration_ms: duration.round(2)
      ))

      Sentry.capture_exception(e)
    end

    raise
  end
end
