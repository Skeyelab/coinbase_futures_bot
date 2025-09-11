# frozen_string_literal: true

require "rails_helper"

RSpec.describe Position, type: :model do
  let(:trading_pair) { TradingPair.create!(product_id: "BIT-29AUG25-CDE", base_currency: "BTC", quote_currency: "USD", enabled: true) }

  let(:valid_position) do
    Position.new(
      product_id: "BIT-29AUG25-CDE",
      side: "LONG",
      size: 2.0,
      entry_price: 50000.0,
      entry_time: Time.current,
      status: "OPEN",
      day_trading: true,
      take_profit: 50200.0,
      stop_loss: 49850.0
    )
  end

  describe "validations" do
    it "is valid with valid attributes" do
      expect(valid_position).to be_valid
    end

    it "requires product_id" do
      position = Position.new(
        side: "LONG",
        size: 2.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
      expect(position).not_to be_valid
      expect(position.errors[:product_id]).to include("can't be blank")
    end

    it "requires side" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        size: 2.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
      expect(position).not_to be_valid
      expect(position.errors[:side]).to include("can't be blank")
    end

    it "requires side to be LONG or SHORT" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "INVALID",
        size: 2.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
      expect(position).not_to be_valid
      expect(position.errors[:side]).to include("is not included in the list")
    end

    it "requires size" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
      expect(position).not_to be_valid
      expect(position.errors[:size]).to include("can't be blank")
    end

    it "requires size to be greater than 0" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
      expect(position).not_to be_valid
      expect(position.errors[:size]).to include("must be greater than 0")
    end

    it "requires entry_price" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 2.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
      expect(position).not_to be_valid
      expect(position.errors[:entry_price]).to include("can't be blank")
    end

    it "requires entry_price to be greater than 0" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 2.0,
        entry_price: 0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
      expect(position).not_to be_valid
      expect(position.errors[:entry_price]).to include("must be greater than 0")
    end

    it "sets entry_time via callback if not provided" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 2.0,
        entry_price: 50000.0,
        status: "OPEN",
        day_trading: true
      )
      expect(position.entry_time).to be_nil
      position.valid?
      expect(position.entry_time).to be_present
    end

    it "sets status via callback if not provided" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 2.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        day_trading: true
      )
      expect(position.status).to be_nil
      position.valid?
      expect(position.status).to eq("OPEN")
    end

    it "requires status to be OPEN or CLOSED" do
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 2.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "INVALID",
        day_trading: true
      )
      expect(position).not_to be_valid
      expect(position.errors[:status]).to include("is not included in the list")
    end

    it "sets day_trading via callback if not provided (defaults to true)" do
      allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 2.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN"
      )
      expect(position.day_trading).to be_nil
      position.valid?
      expect(position.day_trading).to be true
    end

    it "sets day_trading via callback to false when DEFAULT_DAY_TRADING is false" do
      allow(Rails.application.config).to receive(:default_day_trading).and_return(false)
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 2.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN"
      )
      expect(position.day_trading).to be_nil
      position.valid?
      expect(position.day_trading).to be false
    end

    it "respects explicit day_trading value regardless of configuration" do
      allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 2.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: false
      )
      position.valid?
      expect(position.day_trading).to be false
    end
  end

  describe "scopes" do
    let!(:open_position) { Position.create!(product_id: "BIT-29AUG25-CDE", side: "LONG", size: 1.0, entry_price: 50000.0, entry_time: Time.current, status: "OPEN", day_trading: true) }
    let!(:closed_position) { Position.create!(product_id: "ET-29AUG25-CDE", side: "SHORT", size: 1.0, entry_price: 3000.0, entry_time: Time.current, status: "CLOSED", day_trading: true) }
    let!(:day_trading_position) { Position.create!(product_id: "BIT-29AUG25-CDE", side: "LONG", size: 1.0, entry_price: 50000.0, entry_time: Time.current, status: "OPEN", day_trading: true) }
    let!(:swing_trading_position) { Position.create!(product_id: "ET-29AUG25-CDE", side: "LONG", size: 1.0, entry_price: 3000.0, entry_time: Time.current, status: "OPEN", day_trading: false) }
    let!(:today_position) { Position.create!(product_id: "BIT-29AUG25-CDE", side: "LONG", size: 1.0, entry_price: 50000.0, entry_time: Time.current, status: "OPEN", day_trading: true) }
    let!(:yesterday_position) { Position.create!(product_id: "ET-29AUG25-CDE", side: "SHORT", size: 1.0, entry_price: 3000.0, entry_time: 1.day.ago, status: "OPEN", day_trading: true) }

    describe ".open" do
      it "returns only open positions" do
        expect(Position.open).to include(open_position)
        expect(Position.open).not_to include(closed_position)
      end
    end

    describe ".closed" do
      it "returns only closed positions" do
        expect(Position.closed).to include(closed_position)
        expect(Position.closed).not_to include(open_position)
      end
    end

    describe ".day_trading" do
      it "returns only day trading positions" do
        expect(Position.day_trading).to include(day_trading_position)
        expect(Position.day_trading).not_to include(swing_trading_position)
      end
    end

    describe ".swing_trading" do
      it "returns only swing trading positions" do
        expect(Position.swing_trading).to include(swing_trading_position)
        expect(Position.swing_trading).not_to include(day_trading_position)
      end
    end

    describe ".opened_today" do
      it "returns positions opened today" do
        expect(Position.opened_today).to include(today_position)
        expect(Position.opened_today).not_to include(yesterday_position)
      end
    end

    describe ".opened_yesterday" do
      it "returns positions opened yesterday" do
        expect(Position.opened_yesterday).to include(yesterday_position)
        expect(Position.opened_yesterday).not_to include(today_position)
      end
    end

    describe ".expiring_soon" do
      it "returns day trading positions opened yesterday that are still open" do
        expect(Position.expiring_soon).to include(yesterday_position)
      end
    end
  end

  describe "associations" do
    it "belongs to trading_pair" do
      expect(valid_position).to respond_to(:trading_pair)
    end
  end

  describe "callbacks" do
    it "sets default values before create" do
      # Mock Time.current to return a fixed time
      fixed_time = Time.new(2025, 8, 24, 12, 0, 0, "UTC")
      allow(Time).to receive(:current).and_return(fixed_time)

      position = Position.new(
        product_id: "BIT-29AUG25-CDE",
        side: "LONG",
        size: 1.0,
        entry_price: 50000.0
        # Don't set status, entry_time, or day_trading - let callback set them
      )

      position.save!

      expect(position.status).to eq("OPEN")
      expect(position.entry_time).to eq(fixed_time)
      expect(position.day_trading).to be true
    end
  end

  describe "instance methods" do
    let(:position) { Position.create!(product_id: "BIT-29AUG25-CDE", side: "LONG", entry_price: 50000.0, size: 2.0, entry_time: Time.current, status: "OPEN", day_trading: true) }

    describe "#open?" do
      it "returns true for open positions" do
        expect(position.open?).to be true
      end

      it "returns false for closed positions" do
        position.update!(status: "CLOSED")
        expect(position.open?).to be false
      end
    end

    describe "#closed?" do
      it "returns true for closed positions" do
        position.update!(status: "CLOSED")
        expect(position.closed?).to be true
      end

      it "returns false for open positions" do
        expect(position.closed?).to be false
      end
    end

    describe "#long?" do
      it "returns true for LONG positions" do
        expect(position.long?).to be true
      end

      it "returns false for SHORT positions" do
        position.update!(side: "SHORT")
        expect(position.long?).to be false
      end
    end

    describe "#short?" do
      it "returns true for SHORT positions" do
        position.update!(side: "SHORT")
        expect(position.short?).to be true
      end

      it "returns false for LONG positions" do
        expect(position.short?).to be false
      end
    end

    describe "#duration" do
      it "returns duration for open positions" do
        # Create a position with a fixed entry time
        fixed_entry_time = Time.new(2025, 8, 24, 10, 0, 0, "UTC")
        position.update!(entry_time: fixed_entry_time)

        # Mock Time.current to return a fixed future time
        future_time = Time.new(2025, 8, 24, 12, 0, 0, "UTC")
        allow(Time).to receive(:current).and_return(future_time)

        expect(position.duration).to eq(2.hours)
      end

      it "returns duration for closed positions" do
        # Create a position with a fixed entry time
        fixed_entry_time = Time.new(2025, 8, 24, 10, 0, 0, "UTC")
        position.update!(entry_time: fixed_entry_time)

        close_time = Time.new(2025, 8, 24, 12, 0, 0, "UTC")
        position.update!(status: "CLOSED", close_time: close_time)

        # Mock Time.current to return a fixed future time
        future_time = Time.new(2025, 8, 24, 15, 0, 0, "UTC")
        allow(Time).to receive(:current).and_return(future_time)

        expect(position.duration).to eq(2.hours)
      end
    end

    describe "#duration_hours" do
      it "returns duration in hours" do
        # Create a position with a fixed entry time
        fixed_entry_time = Time.new(2025, 8, 24, 10, 0, 0, "UTC")
        position.update!(entry_time: fixed_entry_time)

        # Mock Time.current to return a fixed future time
        future_time = Time.new(2025, 8, 24, 12, 0, 0, "UTC")
        allow(Time).to receive(:current).and_return(future_time)

        expect(position.duration_hours).to eq(2.0)
      end
    end

    describe "#duration_minutes" do
      it "returns duration in minutes" do
        # Create a position with a fixed entry time
        fixed_entry_time = Time.new(2025, 8, 24, 10, 0, 0, "UTC")
        position.update!(entry_time: fixed_entry_time)

        # Mock Time.current to return a fixed future time
        future_time = Time.new(2025, 8, 24, 12, 0, 0, "UTC")
        allow(Time).to receive(:current).and_return(future_time)

        expect(position.duration_minutes).to eq(120.0)
      end
    end

    describe "#age_in_hours" do
      it "returns age in hours" do
        # Create a position with a fixed entry time
        fixed_entry_time = Time.new(2025, 8, 24, 10, 0, 0, "UTC")
        position.update!(entry_time: fixed_entry_time)

        # Mock Time.current to return a fixed future time
        future_time = Time.new(2025, 8, 24, 12, 0, 0, "UTC")
        allow(Time).to receive(:current).and_return(future_time)

        expect(position.age_in_hours).to eq(2.0)
      end
    end

    describe "#age_in_minutes" do
      it "returns age in minutes" do
        # Create a position with a fixed entry time
        fixed_entry_time = Time.new(2025, 8, 24, 10, 0, 0, "UTC")
        position.update!(entry_time: fixed_entry_time)

        # Mock Time.current to return a fixed future time
        future_time = Time.new(2025, 8, 24, 12, 0, 0, "UTC")
        allow(Time).to receive(:current).and_return(future_time)

        expect(position.age_in_minutes).to eq(120.0)
      end
    end

    describe "#needs_same_day_closure?" do
      it "returns true for day trading positions opened yesterday" do
        position.update!(entry_time: 1.day.ago, day_trading: true)
        expect(position.needs_same_day_closure?).to be true
      end

      it "returns false for swing trading positions" do
        position.update!(entry_time: 1.day.ago, day_trading: false)
        expect(position.needs_same_day_closure?).to be false
      end

      it "returns false for closed positions" do
        position.update!(entry_time: 1.day.ago, day_trading: true, status: "CLOSED")
        expect(position.needs_same_day_closure?).to be false
      end
    end

    describe "#needs_closure_soon?" do
      it "returns true for positions older than 23.5 hours" do
        position.update!(entry_time: 24.hours.ago)
        expect(position.needs_closure_soon?).to be true
      end

      it "returns false for positions younger than 23.5 hours" do
        position.update!(entry_time: 23.hours.ago)
        expect(position.needs_closure_soon?).to be false
      end
    end

    describe "#calculate_pnl" do
      it "calculates PnL for long positions" do
        # Long position: (current_price - entry_price) / entry_price * size
        # (51000 - 50000) / 50000 * 2 = 0.04
        pnl = position.calculate_pnl(51000.0)
        expect(pnl).to eq(0.04)
      end

      it "calculates PnL for short positions" do
        position.update!(side: "SHORT")
        # Short position: (entry_price - current_price) / entry_price * size
        # (49000 - 50000) / 50000 * 2 = 0.04
        pnl = position.calculate_pnl(49000.0)
        expect(pnl).to eq(0.04)
      end

      it "returns 0 for closed positions" do
        position.update!(status: "CLOSED")
        pnl = position.calculate_pnl(51000.0)
        expect(pnl).to eq(0)
      end

      it "returns 0 when no current price" do
        pnl = position.calculate_pnl(nil)
        expect(pnl).to eq(0)
      end
    end

    describe "#hit_take_profit?" do
      it "returns true when long position hits take profit" do
        position.update!(take_profit: 51000.0)
        expect(position.hit_take_profit?(51000.0)).to be true
      end

      it "returns true when short position hits take profit" do
        position.update!(side: "SHORT", take_profit: 49000.0)
        expect(position.hit_take_profit?(49000.0)).to be true
      end

      it "returns false when take profit not hit" do
        position.update!(take_profit: 51000.0)
        expect(position.hit_take_profit?(50500.0)).to be false
      end
    end

    describe "#hit_stop_loss?" do
      it "returns true when long position hits stop loss" do
        position.update!(stop_loss: 49000.0)
        expect(position.hit_stop_loss?(49000.0)).to be true
      end

      it "returns true when short position hits stop loss" do
        position.update!(side: "SHORT", stop_loss: 51000.0)
        expect(position.hit_stop_loss?(51000.0)).to be true
      end

      it "returns false when stop loss not hit" do
        position.update!(stop_loss: 49000.0)
        expect(position.hit_stop_loss?(49500.0)).to be false
      end
    end

    describe "#close_position!" do
      it "closes position and sets PnL" do
        close_price = 51000.0
        close_time = Time.current

        position.close_position!(close_price, close_time)

        expect(position.status).to eq("CLOSED")
        expect(position.close_time).to be_within(1.second).of(close_time)
        expect(position.pnl).to eq(0.04) # (51000 - 50000) / 50000 * 2
      end
    end

    describe "#force_close!" do
      it "closes position with reason" do
        close_price = 51000.0
        reason = "Test closure"

        position.force_close!(close_price, reason)

        expect(position.status).to eq("CLOSED")
        expect(position.pnl).to eq(0.04)
      end
    end
  end

  describe "class methods" do
    let!(:day_trading_open) { Position.create!(product_id: "BIT-29AUG25-CDE", side: "LONG", size: 1.0, entry_price: 50000.0, entry_time: Time.current, status: "OPEN", day_trading: true) }
    let!(:day_trading_closed) { Position.create!(product_id: "ET-29AUG25-CDE", side: "SHORT", size: 1.0, entry_price: 3000.0, entry_time: Time.current, status: "CLOSED", day_trading: true) }
    let!(:yesterday_open) { Position.create!(product_id: "ET-29AUG25-CDE", side: "LONG", size: 1.0, entry_price: 3000.0, entry_time: 1.day.ago, status: "OPEN", day_trading: true) }
    let!(:old_closed) { Position.create!(product_id: "ET-29AUG25-CDE", side: "LONG", size: 1.0, entry_price: 3000.0, entry_time: Time.current, status: "CLOSED", close_time: 31.days.ago, day_trading: true) }

    describe ".open_day_trading_positions" do
      it "returns only open day trading positions" do
        open_positions = Position.open_day_trading_positions
        expect(open_positions).to include(day_trading_open)
        expect(open_positions).not_to include(day_trading_closed)
        expect(open_positions).not_to include(yesterday_open)
      end
    end

    describe ".positions_needing_closure" do
      it "returns day trading positions opened yesterday that are still open" do
        expect(Position.positions_needing_closure).to include(yesterday_open)
        expect(Position.positions_needing_closure).not_to include(day_trading_open)
        expect(Position.positions_needing_closure).not_to include(day_trading_closed)
      end
    end

    describe ".positions_approaching_closure" do
      it "returns positions older than 23 hours" do
        old_position = Position.create!(product_id: "BIT-29AUG25-CDE", side: "LONG", size: 1.0, entry_price: 50000.0, entry_time: 24.hours.ago, status: "OPEN", day_trading: true)
        expect(Position.positions_approaching_closure).to include(old_position)
      end
    end

    describe ".close_all_day_trading_positions" do
      it "closes all open day trading positions" do
        close_price = 50000.0
        reason = "Test closure"

        # Count open day trading positions before closure
        initial_open_count = Position.day_trading.open.count

        closed_count = Position.close_all_day_trading_positions(close_price, reason)

        # Should close all open day trading positions
        expect(closed_count).to eq(initial_open_count)
        expect(Position.open_day_trading_positions.count).to eq(0)
      end
    end

    describe ".cleanup_old_positions" do
      it "removes positions older than specified days" do
        deleted_count = Position.cleanup_old_positions(30)
        expect(deleted_count).to eq(1) # old_closed
        expect(Position.exists?(old_closed.id)).to be false
      end
    end
  end
end
