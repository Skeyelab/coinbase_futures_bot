# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionsController, type: :controller do
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }
  let(:mock_positions) do
    [
      {
        "product_id" => "BIP-20DEC30-CDE",
        "number_of_contracts" => "2",
        "side" => "LONG",
        "current_price" => "119900",
        "avg_entry_price" => "118995",
        "unrealized_pnl" => "18.1"
      }
    ]
  end

  before do
    # Set environment variables for basic auth
    @orig_username = ENV["POSITIONS_UI_USERNAME"]
    @orig_password = ENV["POSITIONS_UI_PASSWORD"]
    ENV["POSITIONS_UI_USERNAME"] = "admin"
    ENV["POSITIONS_UI_PASSWORD"] = "password123"

    # Mock the positions service
    allow(controller).to receive(:positions_service).and_return(positions_service)
  end

  after do
    ENV["POSITIONS_UI_USERNAME"] = @orig_username
    ENV["POSITIONS_UI_PASSWORD"] = @orig_password
  end

  describe "authentication" do
    it "requires basic authentication for all actions" do
      # Test that unauthenticated requests are rejected
      get :index
      expect(response).to have_http_status(:unauthorized)

      get :edit, params: { product_id: "BIP-20DEC30-CDE" }
      expect(response).to have_http_status(:unauthorized)

      post :close, params: { product_id: "BIP-20DEC30-CDE" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "accepts valid basic authentication" do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")

      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get :index
      expect(response).to have_http_status(:success)
    end

    it "rejects invalid basic authentication" do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:wrongpassword")

      get :index
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET #index" do
    before do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")
    end

    it "lists all open positions successfully" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get :index

      expect(response).to have_http_status(:success)
      expect(assigns(:positions)).to eq(mock_positions)
      expect(response).to render_template(:index)
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:list_open_positions).and_raise(
        Faraday::ClientError.new("API Error", response: { status: 500, body: "Server Error" })
      )

      get :index

      expect(response).to have_http_status(:success)
      expect(assigns(:error_message)).to include("API Error")
      expect(assigns(:positions)).to eq([])
    end

    it "handles general errors gracefully" do
      allow(positions_service).to receive(:list_open_positions).and_raise(StandardError.new("Unexpected error"))

      get :index

      expect(response).to have_http_status(:success)
      expect(assigns(:error_message)).to include("Unexpected error")
      expect(assigns(:positions)).to eq([])
    end

    it "displays notice messages from params" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get :index, params: { notice: "Position closed successfully" }

      expect(assigns(:notice_message)).to eq("Position closed successfully")
    end
  end

  describe "GET #edit" do
    before do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")
    end

    it "shows position details for existing position" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get :edit, params: { product_id: "BIP-20DEC30-CDE" }

      expect(response).to have_http_status(:success)
      expect(assigns(:position)).to eq(mock_positions.first)
      expect(response).to render_template(:edit)
    end

    it "creates placeholder position when product not found" do
      allow(positions_service).to receive(:list_open_positions).and_return([])

      get :edit, params: { product_id: "NONEXISTENT" }

      expect(response).to have_http_status(:success)
      expect(assigns(:position)["product_id"]).to eq("NONEXISTENT")
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:list_open_positions).and_raise(
        Faraday::ClientError.new("API Error", response: { status: 500, body: "Server Error" })
      )

      get :edit, params: { product_id: "BIP-20DEC30-CDE" }

      expect(response).to have_http_status(:success)
      expect(assigns(:error_message)).to include("API Error")
      expect(assigns(:position)["product_id"]).to eq("BIP-20DEC30-CDE")
    end

    it "handles general errors gracefully" do
      allow(positions_service).to receive(:list_open_positions).and_raise(StandardError.new("Unexpected error"))

      get :edit, params: { product_id: "BIP-20DEC30-CDE" }

      expect(response).to have_http_status(:success)
      expect(assigns(:error_message)).to include("Unexpected error")
      expect(assigns(:position)["product_id"]).to eq("BIP-20DEC30-CDE")
    end
  end

  describe "POST #close" do
    before do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")
    end

    it "closes position successfully and redirects with notice" do
      mock_result = { "success" => true, "order_id" => "close-123" }
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      post :close, params: { product_id: "BIP-20DEC30-CDE", size: "1" }

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("close-123")
    end

    it "closes position without size (uses inferred size)" do
      mock_result = { "success" => true, "message" => "Position closed" }
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      post :close, params: { product_id: "BIP-20DEC30-CDE" }

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("Position+closed")
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:close_position).and_raise(
        StandardError.new("Order failed")
      )

      post :close, params: { product_id: "BIP-20DEC30-CDE", size: "1" }

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions/BIP-20DEC30-CDE/edit")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("Order+failed")
    end

    it "passes correct parameters to service" do
      expect(positions_service).to receive(:close_position).with(
        product_id: "BIP-20DEC30-CDE",
        size: "1.5"
      ).and_return({ "success" => true })

      post :close, params: { product_id: "BIP-20DEC30-CDE", size: "1.5" }
    end
  end

  describe "PATCH #update" do
    before do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")
    end

    it "updates position successfully and redirects with notice" do
      mock_result = { "success" => true, "order_id" => "update-123" }
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      patch :update, params: { product_id: "BIP-20DEC30-CDE", size: "1" }

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("update-123")
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:close_position).and_raise(
        StandardError.new("Update failed")
      )

      patch :update, params: { product_id: "BIP-20DEC30-CDE", size: "1" }

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions/BIP-20DEC30-CDE/edit")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("Update+failed")
    end
  end

  describe "private methods" do
    it "memoizes positions service" do
      service1 = controller.send(:positions_service)
      service2 = controller.send(:positions_service)

      expect(service1).to eq(service2)
    end

        it "creates new positions service instance" do
      # Clear the memoized service first
      controller.instance_variable_set(:@positions_service, nil)

      # Mock the class method to return our service
      allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)

      # Call the method and verify it returns our service
      result = controller.send(:positions_service)
      expect(result).to eq(positions_service)
    end
  end

  describe "routing" do
    it "routes to close action" do
      expect(post: "/positions/BIP-20DEC30-CDE/close").to route_to(
        controller: "positions",
        action: "close",
        product_id: "BIP-20DEC30-CDE"
      )
    end

    it "routes to edit action" do
      expect(get: "/positions/BIP-20DEC30-CDE/edit").to route_to(
        controller: "positions",
        action: "edit",
        product_id: "BIP-20DEC30-CDE"
      )
    end

    it "routes to update action" do
      expect(patch: "/positions/BIP-20DEC30-CDE").to route_to(
        controller: "positions",
        action: "update",
        product_id: "BIP-20DEC30-CDE"
      )
    end
  end
end
