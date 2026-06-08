# frozen_string_literal: true

module Trading
  module PositionManagement
    class BaseWorkflow
      attr_reader :logger

      def initialize(logger: Rails.logger)
        @logger = logger
      end

      private

      def workflow_result(workflow:, status:, details: {})
        WorkflowResult.new(
          workflow: workflow,
          status: status,
          summary: [workflow, "status=#{status}", format_details(details)].compact.join(" ").strip,
          details: details
        )
      end

      def format_details(details)
        return nil if details.empty?

        details
          .compact
          .map { |key, value| "#{key}=#{format_detail_value(value)}" }
          .join(" ")
      end

      def format_detail_value(value)
        case value
        when Float
          value.round(2)
        else
          value
        end
      end

      def send_alert(level, title, details)
        SlackNotificationService.alert(level, title, details)
      end
    end
  end
end
