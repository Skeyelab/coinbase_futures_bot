# frozen_string_literal: true

require "rails_helper"

# Exposure / margin / leverage math on the health dashboard (issue #234 tail).
#
# Six sites in HealthCheckJob computed notional as `size * entry_price`, dropping
# contract_size — the exact bug position.rb:170-181 documents as fixed for PnL
# and which was never applied here. For NOL (contract_size 10) every exposure,
# margin, and leverage figure on the dashboard read ~10x too small.
#
# They also divided by a hardcoded `total_portfolio_value = 100_000.0` while
# Trading::CurrentEquity.usd already existed and is what NotionalCap uses, so
# every percentage was fiction twice over.
RSpec.describe HealthCheckJob, type: :job do
  subject(:job) { described_class.new }

  before do
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(10)
    allow(Trading::CurrentEquity).to receive(:usd).and_return(5_000.0)
  end

  # 2 contracts * $80 * contract_size 10 = $1,600 notional, not $160.
  let!(:position) do
    create(:position, product_id: "NOL-19AUG26-CDE", day_trading: true,
      size: 2, entry_price: 80.0)
  end

  describe "day-trading exposure" do
    it "counts contract_size in notional" do
      # $1,600 of $5,000 equity = 32%. Dropping contract_size gave 3.2%;
      # dropping equity too gave 0.16%.
      expect(job.send(:calculate_day_trading_exposure)).to be_within(1e-6).of(32.0)
    end
  end

  describe "day-trading margin" do
    it "is 10% of contract-size-aware notional" do
      expect(job.send(:calculate_day_trading_margin, nil)).to be_within(1e-6).of(160.0)
    end
  end

  describe "day-trading leverage" do
    it "is notional over margin, both contract-size-aware" do
      expect(job.send(:calculate_day_trading_leverage, nil)).to be_within(1e-6).of(10.0)
    end
  end

  describe "swing exposure" do
    it "counts contract_size and real equity too" do
      position.update!(day_trading: false)

      expect(job.send(:calculate_swing_trading_exposure)).to be_within(1e-6).of(32.0)
    end
  end

  # CurrentEquity degrades to SignalEquity rather than raising, but a zero or
  # negative equity must not produce a divide-by-zero on the dashboard.
  it "reports zero exposure rather than dividing by zero equity" do
    allow(Trading::CurrentEquity).to receive(:usd).and_return(0.0)

    expect(job.send(:calculate_day_trading_exposure)).to eq(0.0)
  end
end
