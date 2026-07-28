# frozen_string_literal: true

require "rails_helper"
require "rake"

# Exposure percentage in the positions monitoring rake tasks (issue #234 tail).
#
# `calculate_exposure` summed `pos.size * pos.entry_price`, dropping
# contract_size — so on NOL (contract_size 10) every exposure percentage these
# tasks printed, and the threshold that fires the portfolio exposure Slack
# alert, read 10x too small.
#
# It also divided by a hardcoded `total_portfolio_value = 100_000.0` while
# Trading::CurrentEquity.usd already existed and is what NotionalCap and
# HealthCheckJob use (PR #507), so the percentage was fiction twice over.
RSpec.describe "positions monitoring rake helpers", type: :task do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("positions:check_all")
    allow(Trading::CurrentEquity).to receive(:usd).and_return(5_000.0)
  end

  def exposure_for(positions)
    send(:calculate_exposure, positions)
  end

  it "returns zero for no positions" do
    expect(exposure_for(Position.none)).to eq(0.0)
  end

  context "on a contract_size 10 future (NOL)" do
    before { allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(10) }

    # 2 contracts * $80 * contract_size 10 = $1,600 of $5,000 equity = 32%.
    # Dropping contract_size gave 3.2%; dropping equity too gave 0.16%.
    it "counts contract_size and real equity in the percentage" do
      create(:position, product_id: "NOL-19AUG26-CDE", day_trading: true, size: 2, entry_price: 80.0)

      expect(exposure_for(Position.open)).to be_within(1e-6).of(32.0)
    end
  end

  # CurrentEquity degrades rather than raising, but a zero balance must not
  # produce a divide-by-zero inside a monitoring task.
  it "reports zero exposure rather than dividing by zero equity" do
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(10)
    allow(Trading::CurrentEquity).to receive(:usd).and_return(0.0)
    create(:position, product_id: "NOL-19AUG26-CDE", day_trading: true, size: 2, entry_price: 80.0)

    expect(exposure_for(Position.open)).to eq(0.0)
  end
end
