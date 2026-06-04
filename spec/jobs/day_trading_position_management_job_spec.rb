# frozen_string_literal: true

require "rails_helper"

RSpec.describe DayTradingPositionManagementJob, type: :job do
  let(:workflow) { instance_double(PositionManagement::DayTradingManagementWorkflow) }
  let(:result) { PositionManagement::WorkflowResult.new(workflow: "day", status: :success, metadata: {}, alerts: []) }
  let(:logger) { instance_double(Logger, info: nil) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(PositionManagement::DayTradingManagementWorkflow).to receive(:new).with(logger: logger).and_return(workflow)
    allow(workflow).to receive(:call).and_return(result)
  end

  it "delegates execution to day-trading orchestration workflow" do
    expect(workflow).to receive(:call)

    described_class.new.perform
  end

  it "logs the top-level orchestration result" do
    expect(logger).to receive(:info).with("Day trading position management job result: #{result.to_h}")

    described_class.new.perform
  end

  it "uses the critical queue" do
    expect(described_class.queue_name).to eq("critical")
  end
end
