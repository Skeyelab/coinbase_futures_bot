# frozen_string_literal: true

require "rails_helper"

# Margin requirement math (issue #234 tail, fourth recurrence).
#
# `calculate_position_margin_requirement` computed position value as
# `position.size * position.entry_price`, dropping contract_size. On NOL
# (contract_size 10) the requirement it reports — and that the overnight
# margin alert carries — was 10x too small, so the gate that exists to force
# swing positions flat before the overnight step-up understated every position
# it looked at.
RSpec.describe MarginWindowMonitoringJob, type: :job do
  subject(:job) { described_class.new }

  let(:intraday) { {"margin_window" => {"margin_window_type" => "INTRADAY_MARGIN"}} }
  let(:overnight) { {"margin_window" => {"margin_window_type" => "OVERNIGHT_MARGIN"}} }

  describe "#calculate_position_margin_requirement" do
    context "on a contract_size 10 future (NOL)" do
      let(:position) do
        build(:position, product_id: "NOL-19AUG26-CDE", size: 2, entry_price: 80.0)
      end

      before { allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(10) }

      # 2 contracts * $80 * contract_size 10 = $1,600 notional.
      it "takes 10% of contract_size-aware notional intraday" do
        expect(job.send(:calculate_position_margin_requirement, position, intraday))
          .to be_within(1e-6).of(160.0)
      end

      it "takes 20% of contract_size-aware notional overnight" do
        expect(job.send(:calculate_position_margin_requirement, position, overnight))
          .to be_within(1e-6).of(320.0)
      end
    end

    # The other direction: a fractional contract must not be over-stated.
    context "on a contract_size 0.01 future (BIP)" do
      let(:position) do
        build(:position, product_id: "BIP-20DEC30-CDE", size: 3, entry_price: 100_000.0)
      end

      before { allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01) }

      # 3 contracts * $100,000 * 0.01 = $3,000 notional, 10% = $300.
      it "takes 10% of contract_size-aware notional intraday" do
        expect(job.send(:calculate_position_margin_requirement, position, intraday))
          .to be_within(1e-6).of(300.0)
      end
    end
  end
end
