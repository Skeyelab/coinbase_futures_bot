# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrailingStopRunnerJob, type: :job do
  let(:runner) { instance_double(Trading::TrailingStop::Runner) }

  before do
    allow(Trading::TrailingStop::Runner).to receive(:new).and_return(runner)
    allow(runner).to receive(:close_triggered_positions).and_return({closed_count: 2, processed_ids: [1, 2]})
  end

  it "runs the trailing stop runner and returns summary" do
    result = described_class.perform_now

    expect(runner).to have_received(:close_triggered_positions).with(positions: Position.open)
    expect(result[:closed_count]).to eq(2)
  end

  it "raises errors from runner failures" do
    allow(runner).to receive(:close_triggered_positions).and_raise(StandardError, "boom")
    expect { described_class.perform_now }.to raise_error(StandardError, "boom")
  end
end
