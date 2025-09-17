# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::PositionsController, type: :controller do
  describe "GET #index" do
    let!(:day_position) { create(:position, day_trading: true, status: "OPEN") }
    let!(:swing_position) { create(:position, day_trading: false, status: "OPEN") }
    let!(:closed_position) { create(:position, day_trading: true, status: "CLOSED") }

    context "without type filter" do
      it "returns all open positions" do
        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response["positions"].length).to eq(2)
        expect(json_response["summary"]).to include(
          "day_trading_count" => 1,
          "swing_trading_count" => 1,
          "total_count" => 2
        )
      end
    end

    context "with day_trading filter" do
      it "returns only day trading positions" do
        get :index, params: {type: "day_trading"}

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response["positions"].length).to eq(1)
        expect(json_response["positions"].first["position_type"]).to eq("day_trading")
      end
    end

    context "with swing_trading filter" do
      it "returns only swing trading positions" do
        get :index, params: {type: "swing_trading"}

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response["positions"].length).to eq(1)
        expect(json_response["positions"].first["position_type"]).to eq("swing_trading")
      end
    end

    context "with product filter" do
      let!(:btc_position) { create(:position, product_id: "BTC-USD", status: "OPEN") }

      it "filters by product_id" do
        get :index, params: {product_id: "BTC-USD"}

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response["positions"].length).to eq(1)
        expect(json_response["positions"].first["product_id"]).to eq("BTC-USD")
      end
    end

    context "when database error occurs" do
      before do
        allow(Position).to receive(:open).and_raise(StandardError.new("Database error"))
      end

      it "returns error response" do
        get :index

        expect(response).to have_http_status(:internal_server_error)
        json_response = JSON.parse(response.body)

        expect(json_response).to include(
          "error" => "Failed to retrieve positions",
          "message" => "Database error"
        )
      end
    end
  end

  describe "GET #summary" do
    let!(:day_position) { create(:position, day_trading: true, status: "OPEN", entry_time: 2.hours.ago) }
    let!(:swing_position) { create(:position, day_trading: false, status: "OPEN", entry_time: 3.days.ago) }
    let!(:old_day_position) { create(:position, day_trading: true, status: "OPEN", entry_time: 25.hours.ago) }

    it "returns comprehensive position summary" do
      get :summary

      expect(response).to have_http_status(:success)
      json_response = JSON.parse(response.body)

      expect(json_response).to include(
        "day_trading" => hash_including(
          "count" => 2,
          "positions_needing_closure" => 1,
          "positions_approaching_closure" => 1
        ),
        "swing_trading" => hash_including(
          "count" => 1
        ),
        "overall" => hash_including(
          "total_positions" => 3
        )
      )
    end

    it "includes exposure calculations" do
      get :summary

      expect(response).to have_http_status(:success)
      json_response = JSON.parse(response.body)

      expect(json_response["day_trading"]).to include("exposure_percentage")
      expect(json_response["swing_trading"]).to include("exposure_percentage")
    end

    it "includes duration calculations" do
      get :summary

      expect(response).to have_http_status(:success)
      json_response = JSON.parse(response.body)

      expect(json_response["day_trading"]).to include("average_duration_hours")
      expect(json_response["swing_trading"]).to include("average_duration_days")
    end
  end

  describe "GET #exposure" do
    let!(:day_position) { create(:position, day_trading: true, status: "OPEN", size: 1, entry_price: 50_000) }
    let!(:swing_position) { create(:position, day_trading: false, status: "OPEN", size: 0.5, entry_price: 40_000) }

    before do
      # Mock the configuration
      allow(Rails.application.config).to receive(:monitoring_config).and_return({
        max_day_trading_exposure: 0.3,
        max_swing_trading_exposure: 0.2
      })
    end

    it "returns exposure data with limits" do
      get :exposure

      expect(response).to have_http_status(:success)
      json_response = JSON.parse(response.body)

      expect(json_response).to include(
        "day_trading_exposure" => a_kind_of(Numeric),
        "swing_trading_exposure" => a_kind_of(Numeric),
        "total_exposure" => a_kind_of(Numeric),
        "limits" => {
          "max_day_trading" => 30.0,
          "max_swing_trading" => 20.0
        },
        "warnings" => a_kind_of(Array),
        "healthy" => be_in([true, false])
      )
    end

    it "identifies when exposure exceeds limits" do
      # Create large positions to exceed limits
      create(:position, day_trading: true, status: "OPEN", size: 10, entry_price: 50_000)

      get :exposure

      expect(response).to have_http_status(:success)
      json_response = JSON.parse(response.body)

      expect(json_response["healthy"]).to be false
      expect(json_response["warnings"]).not_to be_empty
    end
  end

  describe "position serialization" do
    let!(:position) { create(:position, day_trading: true, pnl: 100.50, take_profit: 55_000, stop_loss: 45_000) }

    it "includes all required fields" do
      get :index

      expect(response).to have_http_status(:success)
      json_response = JSON.parse(response.body)
      position_data = json_response["positions"].first

      expect(position_data).to include(
        "id",
        "product_id",
        "side",
        "size",
        "entry_price",
        "entry_time",
        "status",
        "pnl",
        "take_profit",
        "stop_loss",
        "day_trading",
        "position_type",
        "duration_hours",
        "created_at",
        "updated_at"
      )
    end

    it "correctly identifies position type" do
      get :index

      expect(response).to have_http_status(:success)
      json_response = JSON.parse(response.body)
      position_data = json_response["positions"].first

      if position_data["day_trading"]
        expect(position_data["position_type"]).to eq("day_trading")
      else
        expect(position_data["position_type"]).to eq("swing_trading")
      end
    end
  end
end
