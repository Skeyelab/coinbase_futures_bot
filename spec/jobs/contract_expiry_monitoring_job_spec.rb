# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContractExpiryMonitoringJob, type: :job do
  let(:workflow) { instance_double(PositionManagement::ContractExpiryMonitoringWorkflow) }
  let(:result) { PositionManagement::WorkflowResult.new(workflow: "expiry", status: :success, metadata: {}, alerts: []) }
  let(:logger) { instance_double(Logger, info: nil) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(PositionManagement::ContractExpiryMonitoringWorkflow).to receive(:new).with(logger: logger).and_return(workflow)
    allow(workflow).to receive(:call).and_return(result)
  end

  it "delegates execution to contract expiry orchestration workflow" do
    expect(workflow).to receive(:call).with(buffer_days: nil, emergency_check: false)

    described_class.new.perform
  end

  it "passes through workflow arguments" do
    expect(workflow).to receive(:call).with(buffer_days: 5, emergency_check: true)

    described_class.new.perform(buffer_days: 5, emergency_check: true)
  end

  it "logs the top-level orchestration result" do
    expect(logger).to receive(:info).with("Contract expiry monitoring job result: #{result.to_h}")

    described_class.new.perform
  end

  it "uses the critical queue" do
    expect(described_class.queue_name).to eq("critical")
  end
end
