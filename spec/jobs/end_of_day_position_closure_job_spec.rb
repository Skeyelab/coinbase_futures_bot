# frozen_string_literal: true

require "rails_helper"

RSpec.describe EndOfDayPositionClosureJob, type: :job do
  let(:workflow) { instance_double(PositionManagement::EndOfDayClosureWorkflow) }
  let(:result) { PositionManagement::WorkflowResult.new(workflow: "end_of_day", status: :success, metadata: {}, alerts: []) }
  let(:logger) { instance_double(Logger, info: nil) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(PositionManagement::EndOfDayClosureWorkflow).to receive(:new).with(logger: logger).and_return(workflow)
    allow(workflow).to receive(:call).and_return(result)
  end

  it "delegates execution to end-of-day orchestration workflow" do
    expect(workflow).to receive(:call)

    described_class.new.perform
  end

  it "logs the top-level orchestration result" do
    expect(logger).to receive(:info).with("End-of-day position closure job result: #{result.to_h}")

    described_class.new.perform
  end

  it "uses the critical queue" do
    expect(described_class.queue_name).to eq("critical")
  end
end
