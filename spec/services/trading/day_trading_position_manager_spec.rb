# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::DayTradingPositionManager do
  let(:manager) { described_class.new }

  describe "#positions_needing_closure" do
    let!(:yesterday_position) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: 1.day.ago,
        status: "OPEN",
        day_trading: true
      )
    end

    let!(:today_position) do
      Position.create!(
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end

    it "returns positions opened yesterday that are still open" do
      result = manager.positions_needing_closure
      expect(result).to include(yesterday_position)
      expect(result).not_to include(today_position)
    end

    it "returns empty array when no positions need closure" do
      yesterday_position.update!(status: "CLOSED")
      result = manager.positions_needing_closure
      expect(result).to be_empty
    end
  end

  describe "#positions_approaching_closure" do
    let!(:old_position) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: 24.hours.ago,
        status: "OPEN",
        day_trading: true
      )
    end

    let!(:recent_position) do
      Position.create!(
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        entry_time: 12.hours.ago,
        status: "OPEN",
        day_trading: true
      )
    end

    it "returns positions older than 23 hours" do
      result = manager.positions_approaching_closure
      expect(result).to include(old_position)
      expect(result).not_to include(recent_position)
    end
  end

  describe "#check_tp_sl_triggers" do
    let!(:long_position) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true,
        take_profit: 51000.0,
        stop_loss: 49000.0
      )
    end

    let!(:short_position) do
      Position.create!(
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true,
        take_profit: 2900.0,
        stop_loss: 3100.0
      )
    end

    before do
      allow(manager).to receive(:get_current_prices).and_return({
        long_position.id => 51100.0,  # Above take profit
        short_position.id => 2890.0   # Below take profit
      })
    end

    it "returns positions with triggered take profit" do
      result = manager.check_tp_sl_triggers
      expect(result.length).to eq(2)
      
      long_trigger = result.find { |r| r[:position].id == long_position.id }
      expect(long_trigger[:trigger]).to eq("take_profit")
      expect(long_trigger[:current_price]).to eq(51100.0)
      expect(long_trigger[:target_price]).to eq(51000.0)
      
      short_trigger = result.find { |r| r[:position].id == short_position.id }
      expect(short_trigger[:trigger]).to eq("take_profit")
      expect(short_trigger[:current_price]).to eq(2890.0)
      expect(short_trigger[:target_price]).to eq(2900.0)
    end

    it "returns empty array when no triggers are hit" do
      allow(manager).to receive(:get_current_prices).and_return({
        long_position.id => 50000.0,  # No trigger
        short_position.id => 3000.0   # No trigger
      })
      
      result = manager.check_tp_sl_triggers
      expect(result).to be_empty
    end
  end

  describe "#close_tp_sl_positions" do
    let!(:position) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true,
        take_profit: 51000.0
      )
    end

    before do
      allow(manager).to receive(:get_current_prices).and_return({
        position.id => 51100.0
      })
    end

    it "closes positions with triggered TP/SL" do
      expect {
        manager.close_tp_sl_positions
      }.to change { position.reload.status }.from("OPEN").to("CLOSED")
    end

    it "returns count of closed positions" do
      result = manager.close_tp_sl_positions
      expect(result).to eq(1)
    end
  end

  describe "#force_close_all_day_trading_positions" do
    let!(:position1) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end

    let!(:position2) do
      Position.create!(
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end

    let!(:swing_position) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: false
      )
    end

    before do
      allow(manager).to receive(:get_current_prices).and_return({
        position1.id => 50000.0,
        position2.id => 3000.0
      })
    end

    it "closes all open day trading positions" do
      expect {
        manager.force_close_all_day_trading_positions
      }.to change { Position.open.count }.by(-2)
      
      expect(position1.reload.status).to eq("CLOSED")
      expect(position2.reload.status).to eq("CLOSED")
      expect(swing_position.reload.status).to eq("OPEN") # Not affected
    end

    it "returns count of closed positions" do
      result = manager.force_close_all_day_trading_positions
      expect(result).to eq(2)
    end
  end

  describe "#calculate_total_pnl" do
    let!(:position1) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end

    let!(:position2) do
      Position.create!(
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end

    before do
      allow(manager).to receive(:get_current_prices).and_return({
        position1.id => 51000.0,  # +2% PnL
        position2.id => 2900.0    # +3.33% PnL
      })
    end

    it "calculates total PnL for all open day trading positions" do
      # Mock the get_current_prices method to return our test values
      allow(manager).to receive(:get_current_prices).and_return({
        position1.id => 51000.0,  # +2% PnL
        position2.id => 2900.0    # +3.33% PnL
      })
      
      result = manager.calculate_total_pnl
      # Expected PnL: (51000 - 50000) / 50000 * 1.0 = 0.02 = 2%
      # Expected PnL: (3000 - 2900) / 3000 * 1.0 = 0.0333... = 3.33%
      # Total: 2% + 3.33% = 5.33%
      expect(result).to be_within(0.01).of(0.0533) # 5.33% as decimal
    end

    it "returns 0 when no positions exist" do
      Position.destroy_all
      result = manager.calculate_total_pnl
      expect(result).to eq(0)
    end
  end

  describe "#get_current_prices" do
    let!(:position) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end

    it "returns current prices for open day trading positions" do
      # Mock the private method that actually gets the price
      allow(manager).to receive(:get_current_price_for_position).with(position).and_return(51000.0)

      result = manager.get_current_prices
      expect(result[position.id]).to eq(51000.0)
    end

    it "handles API errors gracefully" do
      # Mock the private method to return nil (simulating an error)
      allow(manager).to receive(:get_current_price_for_position).with(position).and_return(nil)

      result = manager.get_current_prices
      expect(result[position.id]).to be_nil
    end
  end

  describe "#close_expired_positions" do
    let!(:expired_position) do
      Position.create!(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: 25.hours.ago,
        status: "OPEN",
        day_trading: true
      )
    end

    let!(:recent_position) do
      Position.create!(
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        entry_time: 12.hours.ago,
        status: "OPEN",
        day_trading: true
      )
    end

    before do
      allow(manager).to receive(:get_current_prices).and_return({
        expired_position.id => 50000.0,
        recent_position.id => 3000.0
      })
    end

    it "closes only expired positions" do
      expect {
        manager.close_expired_positions
      }.to change { expired_position.reload.status }.from("OPEN").to("CLOSED")
      
      expect(recent_position.reload.status).to eq("OPEN") # Not expired
    end

    it "returns count of closed positions" do
      result = manager.close_expired_positions
      expect(result).to eq(1)
    end
  end
end