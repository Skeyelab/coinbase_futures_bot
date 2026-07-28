# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CoinbasePositions Integration with Position Model" do
  let(:service) { Trading::CoinbasePositions.new }
  let(:product_id) { "BIT-29AUG25-CDE" }

  before do
    # Mock the JWT generation to avoid real crypto operations during testing
    allow_any_instance_of(Trading::CoinbasePositions).to receive(:build_jwt_token).and_return("test-jwt-token")

    # Mock the credentials loading specifically
    allow_any_instance_of(Trading::CoinbasePositions).to receive(:load_credentials_from_file).and_return({
      api_key: "organizations/test-org/apiKeys/test-key",
      private_key: "test-private-key"
    })

    # Mock the current market price for PnL calculations (close price of 51,000)
    allow_any_instance_of(Trading::CoinbasePositions).to receive(:get_current_market_price).and_return(51_000.0)

    # Mock all HTTP requests to prevent real API calls
    # Create mock response objects that have .body method returning JSON strings
    mock_post_response = double("Response", body: {
      "order_id" => "test-order-123",
      "status" => "FILLED",
      "success" => true
    }.to_json)

    mock_get_response = double("Response", body: {
      "positions" => [
        {
          "product_id" => "BIT-29AUG25-CDE",
          "side" => "LONG",
          "size" => "1.0",
          "number_of_contracts" => "1.0",
          "entry_price" => "50000.0",
          "unrealized_pnl" => "1000.0"
        }
      ]
    }.to_json)

    allow_any_instance_of(Trading::CoinbasePositions).to receive(:authenticated_post).and_return(mock_post_response)
    allow_any_instance_of(Trading::CoinbasePositions).to receive(:authenticated_get).and_return(mock_get_response)
  end

  describe "position creation integration" do
    it "creates local Position record when opening a position" do
      expect do
        service.open_position(
          product_id: product_id,
          side: "LONG",
          size: 1.0,
          price: 50_000.0
        )
      end.to change(Position, :count).by(1)

      position = Position.last
      expect(position.product_id).to eq(product_id)
      expect(position.side).to eq("LONG")
      expect(position.size).to eq(1.0)
      expect(position.entry_price).to eq(50_000.0)
      expect(position.status).to eq("OPEN")
      expect(position.day_trading).to be true
    end

    it "sets correct defaults for new positions" do
      service.open_position(
        product_id: product_id,
        side: "SHORT",
        size: 2.0,
        price: 3000.0
      )

      position = Position.last
      expect(position.entry_time).to be_present
      expect(position.day_trading).to be true
      expect(position.status).to eq("OPEN")
    end
  end

  describe "position closure integration" do
    let!(:position) do
      Position.create!(
        product_id: product_id,
        side: "LONG",
        size: 1.0,
        entry_price: 50_000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end

    it "updates local Position record when closing a position" do
      expect do
        service.close_position(product_id: product_id, size: 1.0)
      end.to change { position.reload.status }.from("OPEN").to("CLOSED")

      expect(position.close_time).to be_present
      expect(position.pnl).to be_present
    end

    it "calculates PnL correctly when closing position" do
      service.close_position(product_id: product_id, size: 1.0)

      position.reload
      # Dollar unrealized: (51000 - 50000) * 1 contract * contract_size 1
      expected_pnl = (51_000.0 - 50_000.0) * 1.0
      expect(position.pnl).to be_within(0.01).of(expected_pnl)
    end
  end

  # The live/paper close path, exercised WITHOUT stubbing #close_position — the
  # only shape that can see this bug. Every partial-close spec elsewhere stubs
  # the service, so #update_local_position_record never ran and its full-close
  # of a partial request went unnoticed.
  describe "partial position closure integration" do
    let!(:position) do
      Position.create!(
        product_id: product_id,
        side: "LONG",
        size: 5.0,
        entry_price: 50_000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true,
        entry_fee: 5.0
      )
    end

    before do
      # Five contracts open at the venue, so the reduce-only cap leaves the
      # requested partial size alone.
      allow_any_instance_of(Trading::CoinbasePositions).to receive(:authenticated_get).and_return(
        double("Response", body: {
          "positions" => [
            {"product_id" => product_id, "side" => "LONG", "number_of_contracts" => "5.0"}
          ]
        }.to_json)
      )
    end

    it "reduces the tracked position instead of closing it" do
      service.close_position(product_id: product_id, size: 2.0)

      position.reload
      expect(position.status).to eq("OPEN")
      expect(position.size).to eq(3.0)
    end
  end

  # Two OPEN rows on one product is the only shape that can see this bug. The
  # re-find by product picks the newest row and averages a fill into a position
  # that never took it; with a single row it lands on the right record by luck,
  # which is why every existing example passed.
  describe "increase targets the row the caller resolved" do
    let!(:older) do
      Position.create!(
        product_id: product_id, side: "LONG", size: 1.0, entry_price: 40_000.0,
        entry_time: 2.hours.ago, status: "OPEN", day_trading: true
      )
    end

    let!(:newer) do
      Position.create!(
        product_id: product_id, side: "LONG", size: 1.0, entry_price: 60_000.0,
        entry_time: 1.hour.ago, status: "OPEN", day_trading: true
      )
    end

    it "increases the passed row and leaves the other untouched" do
      service.increase_position(product_id: product_id, size: 1.0, position: older)

      older.reload
      expect(older.size).to eq(2.0)
      # (1 @ 40,000 + 1 @ 51,000) / 2
      expect(older.entry_price).to be_within(0.01).of(45_500.0)

      newer.reload
      expect(newer.size).to eq(1.0)
      expect(newer.entry_price).to eq(60_000.0)
    end

    # This is the live order path. Guessing which of two positions to grow is a
    # real-money error, so an unresolvable target refuses BEFORE the order goes
    # out — nothing sent, nothing mutated.
    it "refuses to guess, and places no order, when no row was resolved" do
      expect(service).not_to receive(:submit_order)

      expect do
        service.increase_position(product_id: product_id, size: 1.0)
      end.to raise_error(Trading::CoinbasePositions::AmbiguousPositionError, /2 open positions/)

      expect(older.reload.size).to eq(1.0)
      expect(older.entry_price).to eq(40_000.0)
      expect(newer.reload.size).to eq(1.0)
      expect(newer.entry_price).to eq(60_000.0)
    end
  end

  describe "position updates integration" do
    let!(:position) do
      Position.create!(
        product_id: product_id,
        side: "LONG",
        size: 1.0,
        entry_price: 50_000.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end

    it "updates local Position record when modifying position" do
      new_size = 1.5
      new_price = 52_000.0

      service.update_current_month_position(product_id, new_size, new_price)

      position.reload
      expect(position.size).to eq(new_size)
      expect(position.entry_price).to eq(new_price)
    end
  end

  describe "error handling integration" do
    it "handles API errors gracefully without affecting local records" do
      allow_any_instance_of(Trading::CoinbasePositions).to receive(:authenticated_post)
        .and_raise(StandardError, "API Error")

      expect do
        service.open_position(
          product_id: product_id,
          side: "LONG",
          size: 1.0,
          price: 50_000.0
        )
      end.to raise_error(StandardError)

      # No local position should be created if API fails
      expect(Position.where(product_id: product_id)).to be_empty
    end

    it "raises errors when API calls fail" do
      allow_any_instance_of(Trading::CoinbasePositions).to receive(:authenticated_post)
        .and_raise(StandardError, "API Error")

      expect do
        service.open_position(
          product_id: product_id,
          side: "LONG",
          size: 1.0,
          price: 50_000.0
        )
      end.to raise_error(StandardError, "API Error")
    end
  end

  describe "position synchronization" do
    it "can retrieve current market prices for positions" do
      # Create recent tick for price data
      Tick.create!(
        product_id: product_id,
        price: 51_000.0,
        observed_at: 1.minute.ago
      )

      price = service.get_current_market_price(product_id)
      expect(price).to eq(51_000.0)
    end

    it "handles price retrieval errors gracefully" do
      # Override the mock to return nil for this specific test
      allow(service).to receive(:get_current_market_price).and_return(nil)

      # No recent price data available
      price = service.get_current_market_price(product_id)
      expect(price).to be_nil
    end
  end

  describe "day trading configuration behavior" do
    context "when DEFAULT_DAY_TRADING is true" do
      before do
        allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
      end

      it "creates day trading positions by default" do
        service.open_position(
          product_id: product_id,
          side: "LONG",
          size: 1.0,
          price: 50_000.0
        )

        position = Position.last
        expect(position.day_trading).to be true
      end

      it "allows explicit swing trading override" do
        service.open_position(
          product_id: product_id,
          side: "LONG",
          size: 1.0,
          price: 50_000.0,
          day_trading: false
        )

        position = Position.last
        expect(position.day_trading).to be false
      end
    end

    context "when DEFAULT_DAY_TRADING is false" do
      before do
        allow(Rails.application.config).to receive(:default_day_trading).and_return(false)
      end

      # Venue-aware now: the global flag only decides when the venue is unknown.
      # A perp is held (no session to be flat before); a dated contract stays
      # intraday regardless. Asserting via a perp so this tests the default
      # rather than the venue rule.
      it "creates swing trading positions by default" do
        FundingRate.create!(product_id: product_id, funding_time: 1.hour.ago,
          funding_rate: 0.000013, funding_interval_seconds: 3600, observed_at: 1.hour.ago)

        service.open_position(
          product_id: product_id,
          side: "LONG",
          size: 1.0,
          price: 50_000.0
        )

        position = Position.last
        expect(position.day_trading).to be false
      end

      it "allows explicit day trading override" do
        service.open_position(
          product_id: product_id,
          side: "LONG",
          size: 1.0,
          price: 50_000.0,
          day_trading: true
        )

        position = Position.last
        expect(position.day_trading).to be true
      end
    end
  end

  describe "day trading specific behavior" do
    it "creates positions with day_trading flag set to true by default" do
      service.open_position(
        product_id: product_id,
        side: "LONG",
        size: 1.0,
        price: 50_000.0
      )

      position = Position.last
      expect(position.day_trading).to be true
    end

    it "allows positions to be created with explicit day_trading setting" do
      service.open_position(
        product_id: product_id,
        side: "SHORT",
        size: 2.0,
        price: 3000.0,
        day_trading: false
      )

      position = Position.last
      expect(position.day_trading).to be false
    end
  end

  describe "kill switch guard" do
    before do
      allow(TradingHalt).to receive(:assert_active!).and_raise(TradingHalt::HaltedError, "Trading is halted")
    end

    it "raises HaltedError on open_position when halted" do
      expect { service.open_position(product_id: product_id, side: "BUY", size: 1) }
        .to raise_error(TradingHalt::HaltedError)
    end

    # Inverted deliberately (issue #537). This previously asserted that a halt
    # blocks closes — which is the defect, not the contract. A halt that stops
    # exits does not stop the bot holding risk, it pins positions through their
    # own stop-loss. Exits must survive the kill switch.
    it "still CLOSES when halted — a halt must not trap a position past its stop" do
      expect { service.close_position(product_id: product_id) }
        .not_to raise_error
    end

    it "raises HaltedError on increase_position when halted" do
      expect { service.increase_position(product_id: product_id, size: 1) }
        .to raise_error(TradingHalt::HaltedError)
    end
  end
end
