# frozen_string_literal: true

module PositionManagement
  module AlertPolicy
    private

    def notify(alerts, severity:, title:, message:)
      SlackNotificationService.alert(severity, title, message)
      alerts << {severity: severity, title: title, message: message}
    rescue => e
      logger.error("Failed to send alert #{title}: #{e.message}")
    end
  end
end
