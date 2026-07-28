# frozen_string_literal: true

require "rails_helper"

# ADR 0006 decision 2: MAX_LIVE_INSTRUMENTS, default 1, enforced at the entry
# gate alongside global_position_cap / asset_position_cap /
# account_notional_cap / insufficient_buying_power.
#
# Those four all bound what happens AFTER an instrument is live — how many
# positions, how much notional, how much buying power. None bounds how many
# instruments get there, and the growth path is one line in
# Contract::PREFIX_TO_BASE_CURRENCY.
RSpec.describe RapidSignalEvaluationJob, "MAX_LIVE_INSTRUMENTS", type: :job do
  subject(:job) { described_class.new }

  let(:signal) { {side: "BUY", quantity: 1, confidence: 90, price: 100.0, tp: 101.0, sl: 99.0} }

  before do
    job.instance_variable_set(:@logger, Rails.logger)
    job.instance_variable_set(:@asset, "BTC")
    job.instance_variable_set(:@current_price, 100.0)
    job.instance_variable_set(:@target_contract, "BIP-20DEC30-CDE")
    allow(Trading::Protections).to receive(:blocked?).and_return(false)
    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
  end

  def gate = job.send(:should_execute_signal?, signal)

  describe "the default" do
    it "is 1 — the count of instruments that have produced a perp fill is zero" do
      expect(described_class.max_live_instruments).to eq(1)
    end

    it "reads MAX_LIVE_INSTRUMENTS and ignores a nonsensical zero" do
      ClimateControl.modify(MAX_LIVE_INSTRUMENTS: "3") { expect(described_class.max_live_instruments).to eq(3) }
      ClimateControl.modify(MAX_LIVE_INSTRUMENTS: "0") { expect(described_class.max_live_instruments).to eq(1) }
    end
  end

  describe "the runtime arm — distinct instruments already holding positions" do
    it "permits an entry on the instrument that is already the live one" do
      create(:position, product_id: "BIP-20DEC30-CDE", status: "OPEN")

      expect(gate).to be true
    end

    it "rejects an entry that would make a second instrument live" do
      create(:position, product_id: "NOL-30SEP26-CDE", status: "OPEN")

      expect(gate).to be false
    end

    it "permits the second instrument once the cap is raised" do
      create(:position, product_id: "NOL-30SEP26-CDE", status: "OPEN")

      ClimateControl.modify(MAX_LIVE_INSTRUMENTS: "2") { expect(gate).to be true }
    end
  end

  describe "the configuration arm — more symbols enabled than the cap allows" do
    it "rejects every entry when more symbols are enabled than may be live" do
      allow(Trading::SymbolSuspension).to receive(:live_symbols)
        .and_return(%w[BIP-20DEC30-CDE NOL-30SEP26-CDE])

      expect(gate).to be false
    end
  end

  it "records the rejection in the decision ledger under its own reason" do
    create(:position, product_id: "NOL-30SEP26-CDE", status: "OPEN")
    recorder = instance_double(Trading::DecisionRecorder)
    job.instance_variable_set(:@decisions, recorder)
    expect(recorder).to receive(:rejected).with(:live_instrument_cap, hash_including(cap: 1))

    gate
  end
end
