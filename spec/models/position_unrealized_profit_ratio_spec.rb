# frozen_string_literal: true

require "rails_helper"

# Issue #398: MinimumRoiExit needs the position's unrealized PRICE return while
# still open (side-adjusted), in the same units as the strategy's tp_target.
RSpec.describe Position, "#unrealized_profit_ratio" do
  it "is the fractional up-move for a long" do
    pos = build(:position, side: "LONG", entry_price: 100.0, status: "OPEN")
    expect(pos.unrealized_profit_ratio(101.0)).to be_within(1e-9).of(0.01)
    expect(pos.unrealized_profit_ratio(99.0)).to be_within(1e-9).of(-0.01)
  end

  it "is the fractional down-move for a short" do
    pos = build(:position, side: "SHORT", entry_price: 100.0, status: "OPEN")
    expect(pos.unrealized_profit_ratio(99.0)).to be_within(1e-9).of(0.01)
    expect(pos.unrealized_profit_ratio(101.0)).to be_within(1e-9).of(-0.01)
  end

  it "is nil without a usable price or when not open" do
    expect(build(:position, status: "OPEN", entry_price: 100.0).unrealized_profit_ratio(nil)).to be_nil
    expect(build(:position, status: "OPEN", entry_price: 100.0).unrealized_profit_ratio(0)).to be_nil
    expect(build(:position, :closed, entry_price: 100.0).unrealized_profit_ratio(101.0)).to be_nil
  end
end
