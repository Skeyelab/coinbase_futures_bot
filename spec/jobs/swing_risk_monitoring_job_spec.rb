# frozen_string_literal: true

require "rails_helper"

RSpec.describe SwingRiskMonitoringJob, type: :job do
  let(:workflow) { instance_double(PositionManagement::SwingRiskMonitoringWorkflow) }
  let(:result) { PositionManagement::WorkflowResult.new(workflow: "swing_risk", status: :success, metadata: {}, alerts: []) }
  let(:logger) { instance_double(Logger, info: nil) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(PositionManagement::SwingRiskMonitoringWorkflow).to receive(:new).with(logger: logger).and_return(workflow)
    allow(workflow).to receive(:call).and_return(result)
  end

  it "delegates execution to swing risk orchestration workflow" do
    expect(workflow).to receive(:call)

    described_class.new.perform
  end

  it "logs the top-level orchestration result" do
    expect(logger).to receive(:info).with("Swing risk monitoring job result: #{result.to_h}")

    described_class.new.perform
  end

  it "uses the default queue" do
    expect(described_class.queue_name).to eq("default")
  end
end
