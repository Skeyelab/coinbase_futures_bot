# frozen_string_literal: true

module PositionManagement
  class WorkflowResult
    attr_reader :workflow, :status, :metadata, :alerts, :error

    def initialize(workflow:, status:, metadata: {}, alerts: [], error: nil)
      @workflow = workflow
      @status = status
      @metadata = metadata
      @alerts = alerts
      @error = error
    end

    def success?
      status == :success
    end

    def failed?
      !success?
    end

    def to_h
      {
        workflow: workflow,
        status: status,
        metadata: metadata,
        alerts: alerts,
        error: error
      }
    end
  end
end
