# frozen_string_literal: true

require "rails_helper"

# ADR 0006 fails the universe gate closed, which means a misconfiguration stops
# the bot trading. That is the intended direction — but only if the operator can
# see, from the log alone, exactly what to run to dig out. A block whose message
# is "suspended" and nothing more turns a safety default into an outage that
# needs source-diving to end.
#
# These examples pin the recovery instruction to the surfaces that actually
# print it. `universe_scope` so the real fail-closed default is in force.
RSpec.describe "universe gate operator recovery", type: :service, universe_scope: true do
  let(:logger) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil) }

  it "tells the operator the exact command when the rapid entry path blocks a symbol" do
    messages = []
    allow(logger).to receive(:info) { |m| messages << m }
    allow(Rails).to receive(:logger).and_return(logger)

    RapidSignalEvaluationJob.new.perform(
      product_id: "PAU-20DEC30-CDE", current_price: 3400.0, asset: "PAXG"
    )

    expect(messages.join("\n")).to include("bin/futuresbot resume PAU-20DEC30-CDE")
  end

  it "tells the operator the exact command when the realtime evaluator skips a symbol" do
    messages = []
    allow(logger).to receive(:info) { |m| messages << m }
    contract = Contract.create!(product_id: "PAU-20DEC30-CDE", base_currency: "PAXG",
      quote_currency: "USD", expiration_date: Date.new(2030, 12, 20),
      contract_type: "CDE", enabled: true, status: "online")

    RealTimeSignalEvaluator.new(logger: logger).evaluate_pair(contract)

    expect(messages.join("\n")).to include("bin/futuresbot resume PAU-20DEC30-CDE")
  end

  it "tells the operator the exact command when the batch signal job skips a symbol" do
    Contract.create!(product_id: "PAU-20DEC30-CDE", base_currency: "PAXG",
      quote_currency: "USD", expiration_date: Date.new(2030, 12, 20),
      contract_type: "CDE", enabled: true, status: "online")

    expect { GenerateSignalsJob.new.perform(equity_usd: 1000) }
      .to output(/bin\/futuresbot resume PAU-20DEC30-CDE/).to_stdout
  end
end
