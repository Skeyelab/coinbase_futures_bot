# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::DecisionRecorder, type: :service do
  let(:logger) { instance_double(ActiveSupport::Logger, error: nil) }
  subject(:recorder) do
    described_class.new(product_id: "BTC-USD", asset: "BTC", contract_id: "BIT-29AUG25-CDE", logger: logger)
  end

  let(:signal) { {side: "LONG", quantity: 2, confidence: 85.0} }

  it "records a rejection with its reason and signal detail" do
    recorder.rejected(:low_confidence, signal: signal, threshold: 75)

    d = SignalDecision.last
    expect(d.disposition).to eq("rejected")
    expect(d.reason).to eq("low_confidence")
    expect(d.confidence).to eq(85.0)
    expect(d.contract_id).to eq("BIT-29AUG25-CDE")
    expect(d.context["threshold"]).to eq(75)
  end

  it "records a trade with lineage to the position it opened" do
    position = create(:position)

    recorder.traded(signal: signal, position_id: position.id)

    d = SignalDecision.last
    expect(d.disposition).to eq("traded")
    expect(d.reason).to eq("traded")
    expect(d.position).to eq(position)
  end

  it "records a rejection with no signal at all" do
    expect { recorder.rejected(:symbol_suspended) }.to change(SignalDecision, :count).by(1)
    expect(SignalDecision.last.side).to be_nil
  end

  # A ledger write must never take the trading path down: recording is
  # bookkeeping, and a bookkeeping failure must not prevent — or worse, appear
  # to fail — an order that already went through.
  it "swallows and logs a write failure rather than raising" do
    allow(SignalDecision).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "db gone")

    expect { recorder.rejected(:low_confidence, signal: signal) }.not_to raise_error
    expect(logger).to have_received(:error).with(/failed to record low_confidence/)
  end
end
