# frozen_string_literal: true

require "rails_helper"

# A partial close splits one position into two rows. The cost of that position
# has to split with it: the entry fee was paid ONCE for the whole size, so the
# closed portion carries its pro-rata share and the parent keeps the rest.
# Copying it would double-count the cost; dropping it loses it. Both are wrong,
# and with zero validated perp fills (#391) the recorded number is the only
# ground truth this bot has.
RSpec.describe Position, "#close_partial! fees" do
  subject(:parent) do
    create(:position, status: "OPEN", side: "LONG", size: 4.0,
      entry_price: 50_000.0, entry_fee: BigDecimal("8.00"))
  end

  describe "entry fee apportionment" do
    it "moves the closed contracts' pro-rata share of the entry fee to the split row" do
      portion = parent.close_partial!(1.0, 51_000.0)

      expect(portion.entry_fee).to eq(BigDecimal("2.00"))
    end

    it "reduces the parent's entry fee by exactly what the split row took" do
      parent.close_partial!(1.0, 51_000.0)

      expect(parent.reload.entry_fee).to eq(BigDecimal("6.00"))
    end

    # nil means "we never recorded what this cost", 0.0 means "it was free".
    # DailySummaryJob branches on that difference: nil falls through to the
    # venue estimate, 0.0 would be reported as a genuinely costless round trip.
    it "leaves the split row's entry fee unknown when the parent's is unknown" do
      unpriced = create(:position, status: "OPEN", side: "LONG", size: 4.0,
        entry_price: 50_000.0, entry_fee: nil)

      portion = unpriced.close_partial!(1.0, 51_000.0)

      expect(portion.entry_fee).to be_nil
    end
  end
end
