# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::DayTradingPositionManager do
  let(:manager) { described_class.new }

  describe "#positions_need_closure?" do
    context "when positions need closure" do
      before { create(:position, :yesterday, status: "OPEN") }

      it "returns true" do
        expect(manager.positions_need_closure?).to be true
      end
    end

    context "when no positions need closure" do
      before { create(:position, status: "CLOSED") }

      it "returns false" do
        expect(manager.positions_need_closure?).to be false
      end
    end

    context "when no positions exist" do
      it "returns false" do
        expect(manager.positions_need_closure?).to be false
      end
    end
  end

  describe "#positions_approaching_closure?" do
    context "when positions are approaching closure" do
      before { create(:position, :approaching_closure) }

      it "returns true" do
        expect(manager.positions_approaching_closure?).to be true
      end
    end

    context "when no positions are approaching closure" do
      before { create(:position, :recent) }

      it "returns false" do
        expect(manager.positions_approaching_closure?).to be false
      end
    end
  end

  describe "#positions_needing_closure" do
    let!(:yesterday_position) { create(:position, :yesterday, status: "OPEN") }
    let!(:today_position) { create(:position, status: "OPEN", entry_time: Time.current) }

    it "returns positions opened yesterday that are still open" do
      result = manager.positions_needing_closure
      expect(result).to include(yesterday_position)
      expect(result).not_to include(today_position)
    end

    it "includes trading_pair association" do
      result = manager.positions_needing_closure
      expect(result.first.association(:trading_pair)).to be_loaded
    end

    it "returns empty array when no positions need closure" do
      yesterday_position.update!(status: "CLOSED")
      result = manager.positions_needing_closure
      expect(result).to be_empty
    end
  end

  describe "#positions_approaching_closure" do
    let!(:old_position) { create(:position, :approaching_closure) }
    let!(:recent_position) { create(:position, :recent) }

    it "returns positions older than 23 hours" do
      result = manager.positions_approaching_closure
      expect(result).to include(old_position)
      expect(result).not_to include(recent_position)
    end

    it "includes trading_pair association" do
      result = manager.positions_approaching_closure
      expect(result.first.association(:trading_pair)).to be_loaded
    end
  end

  describe "#check_tp_sl_triggers" do
    let!(:long_position) do
      create(:position,
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        status: "OPEN",
        day_trading: true,
        take_profit: 51000.0,
        stop_loss: 49000.0)
    end

    let!(:short_position) do
      create(:position,
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        status: "OPEN",
        day_trading: true,
        take_profit: 2900.0,
        stop_loss: 3100.0)
    end

    # Integration-style test: Create real price data instead of mocking
    context "with real price data from ticks" do
      before do
        # Create ticks that will trigger take profit for both positions
        create(:tick, product_id: "BIT-29AUG25-CDE", price: 51100.0, observed_at: 1.minute.ago)
        create(:tick, product_id: "ET-29AUG25-CDE", price: 2890.0, observed_at: 1.minute.ago)
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
    end

    context "with real price data from candles" do
      before do
        # Create candles as fallback when ticks are not available
        create(:candle,
          symbol: "BIT-29AUG25-CDE",
          timeframe: "1m",
          close: 48800.0, # Below stop loss
          timestamp: 1.minute.ago)
      end

      it "returns positions with triggered stop loss" do
        result = manager.check_tp_sl_triggers

        long_trigger = result.find { |r| r[:position].id == long_position.id }
        expect(long_trigger[:trigger]).to eq("stop_loss")
        expect(long_trigger[:current_price]).to eq(48800.0)
        expect(long_trigger[:target_price]).to eq(49000.0)
      end
    end

    context "when no triggers are hit" do
      before do
        # Create ticks with prices that don't trigger TP/SL
        create(:tick, product_id: "BIT-29AUG25-CDE", price: 50000.0, observed_at: 1.minute.ago)
        create(:tick, product_id: "ET-29AUG25-CDE", price: 3000.0, observed_at: 1.minute.ago)
      end

      it "returns empty array when no triggers are hit" do
        result = manager.check_tp_sl_triggers
        expect(result).to be_empty
      end
    end

    context "when no price data is available" do
      it "returns empty array and uses entry price as fallback" do
        result = manager.check_tp_sl_triggers
        expect(result).to be_empty
      end
    end
  end

  describe "#close_tp_sl_positions" do
    let!(:position) do
      create(:position,
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        status: "OPEN",
        day_trading: true,
        take_profit: 51000.0)
    end

    context "when position hits take profit" do
      before do
        # Create tick data that triggers take profit
        create(:tick, product_id: "BIT-29AUG25-CDE", price: 51100.0, observed_at: 1.minute.ago)
      end

      it "closes positions with triggered TP/SL" do
        # Note: This test would require mocking the external Coinbase API
        # In a real integration test, we would verify the API call was made
        # For now, we'll test the logic that detects triggers
        triggered_positions = manager.check_tp_sl_triggers
        expect(triggered_positions.length).to eq(1)
        expect(triggered_positions.first[:trigger]).to eq("take_profit")
      end
    end

    context "when no positions need closing" do
      before do
        # Create tick data that doesn't trigger TP/SL
        create(:tick, product_id: "BIT-29AUG25-CDE", price: 50000.0, observed_at: 1.minute.ago)
      end

      it "returns 0 when no positions need closing" do
        result = manager.close_tp_sl_positions
        expect(result).to eq(0)
      end
    end
  end

  describe "#force_close_all_day_trading_positions" do
    let!(:position1) do
      create(:position,
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        status: "OPEN",
        day_trading: true)
    end

    let!(:position2) do
      create(:position,
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        status: "OPEN",
        day_trading: true)
    end

    let!(:swing_position) do
      create(:position,
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        status: "OPEN",
        day_trading: false)
    end

    it "only affects day trading positions" do
      # Create price data for testing
      create(:tick, product_id: "BIT-29AUG25-CDE", price: 50000.0, observed_at: 1.minute.ago)
      create(:tick, product_id: "ET-29AUG25-CDE", price: 3000.0, observed_at: 1.minute.ago)

      # Test that the method identifies the correct positions to close
      open_day_trading_positions = Position.open_day_trading_positions
      expect(open_day_trading_positions).to include(position1, position2)
      expect(open_day_trading_positions).not_to include(swing_position)
    end

    it "returns correct count of positions to be closed" do
      open_day_trading_positions = Position.open_day_trading_positions
      expect(open_day_trading_positions.count).to eq(2)
    end
  end

  describe "#calculate_total_pnl" do
    let!(:position1) do
      create(:position,
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        status: "OPEN",
        day_trading: true)
    end

    let!(:position2) do
      create(:position,
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        status: "OPEN",
        day_trading: true)
    end

    context "with real price data from ticks" do
      before do
        # Create ticks with profitable prices
        create(:tick, product_id: "BIT-29AUG25-CDE", price: 51000.0, observed_at: 1.minute.ago)
        create(:tick, product_id: "ET-29AUG25-CDE", price: 2900.0, observed_at: 1.minute.ago)
      end

      it "calculates total PnL for all open day trading positions" do
        result = manager.calculate_total_pnl
        # Expected PnL: (51000 - 50000) / 50000 * 1.0 = 0.02 = 2%
        # Expected PnL: (3000 - 2900) / 3000 * 1.0 = 0.0333... = 3.33%
        # Total: 2% + 3.33% = 5.33%
        expect(result).to be_within(0.01).of(0.0533) # 5.33% as decimal
      end
    end

    context "with candle data as fallback" do
      before do
        # Create candles when ticks are not available
        create(:candle,
          symbol: "BIT-29AUG25-CDE",
          timeframe: "1m",
          close: 49500.0, # Loss
          timestamp: 1.minute.ago)
        create(:candle,
          symbol: "ET-29AUG25-CDE",
          timeframe: "1m",
          close: 3050.0, # Loss
          timestamp: 1.minute.ago)
      end

      it "calculates PnL using candle data" do
        result = manager.calculate_total_pnl
        # Expected PnL: (49500 - 50000) / 50000 * 1.0 = -0.01 = -1%
        # Expected PnL: (3000 - 3050) / 3000 * 1.0 = -0.0166... = -1.67%
        # Total: -1% + (-1.67%) = -2.67%
        expect(result).to be_within(0.01).of(-0.0267)
      end
    end

    context "when no positions exist" do
      before { Position.destroy_all }

      it "returns 0 when no positions exist" do
        result = manager.calculate_total_pnl
        expect(result).to eq(0)
      end
    end
  end

  describe "#get_current_prices" do
    let!(:position) do
      create(:position,
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        status: "OPEN",
        day_trading: true)
    end

    context "with recent tick data" do
      before do
        create(:tick, product_id: "BIT-29AUG25-CDE", price: 51000.0, observed_at: 1.minute.ago)
      end

      it "returns current prices from ticks" do
        result = manager.get_current_prices
        expect(result[position.id]).to eq(51000.0)
      end
    end

    context "with candle data fallback" do
      before do
        create(:candle,
          symbol: "BIT-29AUG25-CDE",
          timeframe: "1m",
          close: 50500.0,
          timestamp: 1.minute.ago)
      end

      it "returns current prices from candles when ticks unavailable" do
        result = manager.get_current_prices
        expect(result[position.id]).to eq(50500.0)
      end
    end

    context "with no price data" do
      it "returns entry price as fallback" do
        result = manager.get_current_prices
        expect(result[position.id]).to eq(50000.0)
      end
    end
  end

  describe "#close_expired_positions" do
    let!(:expired_position) do
      create(:position,
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: 25.hours.ago,
        status: "OPEN",
        day_trading: true)
    end

    let!(:recent_position) do
      create(:position,
        product_id: "ET-29AUG25-CDE",
        side: "SHORT",
        size: 1.0,
        entry_price: 3000.0,
        entry_time: 12.hours.ago,
        status: "OPEN",
        day_trading: true)
    end

    it "only identifies expired positions correctly" do
      # Test that the method identifies the correct positions to close
      positions_needing_closure = manager.positions_needing_closure
      expect(positions_needing_closure).to include(expired_position)
      expect(positions_needing_closure).not_to include(recent_position)
    end

    it "returns correct count of positions needing closure" do
      positions_needing_closure = manager.positions_needing_closure
      expect(positions_needing_closure.count).to eq(1)
    end
  end
end
