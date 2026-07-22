# frozen_string_literal: true

require "rails_helper"

# Regression: the deduplication guard read @deduplication_window (an Integer
# column, default 300) with `.ago` — but Integer has no #ago (only Numeric#seconds
# etc. return a Duration that responds to #ago). So `300.ago` raised NoMethodError
# on every create attempt, was swallowed by create_signal_alert's rescue, and
# RealTimeSignalEvaluator silently created zero SignalAlerts in production.
#
# The prior evaluator spec never caught this because it stubs duplicate_signal?.
RSpec.describe RealTimeSignalEvaluator, type: :service do
  let(:logger) { instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:evaluator) { described_class.new(logger: logger) }
  let(:contract) { instance_double(Contract, product_id: "BIT-29AUG25-CDE") }
  let(:valid_signal) do
    {side: "long", price: 100.0, confidence: 90.0, sl: 99.0, tp: 101.0, quantity: 5}
  end

  before do
    create(:trading_profile, :active, name: "global")
    allow(evaluator).to receive(:resolve_symbol).and_return("BIT-29AUG25-CDE")
    allow(evaluator).to receive(:has_sufficient_data?).and_return(true)
    allow_any_instance_of(Strategy::MultiTimeframeSignal).to receive(:signal).and_return(valid_signal)
  end

  it "checks the dedup window without raising on the integer column value" do
    expect(evaluator.send(:duplicate_signal?, "MultiTimeframeSignal", "BIT-29AUG25-CDE", valid_signal))
      .to be(false)
  end

  it "actually persists a SignalAlert through the full evaluate path" do
    expect { evaluator.evaluate_pair(contract) }.to change(SignalAlert, :count).by(1)
  end
end
