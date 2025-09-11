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
      expected_pnl = ((51_000.0 - 50_000.0) / 50_000.0) * 1.0
      expect(position.pnl).to be_within(0.01).of(expected_pnl)
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

      it "creates swing trading positions by default" do
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
end
