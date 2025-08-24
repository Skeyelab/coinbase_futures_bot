# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Positions", type: :request do
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
    allow_any_instance_of(PositionsController).to receive(:positions_service).and_return(positions_service)
  end

  after do
    ENV["POSITIONS_UI_USERNAME"] = @orig_username
    ENV["POSITIONS_UI_PASSWORD"] = @orig_password
  end

  describe "authentication" do
    it "requires basic authentication for all endpoints" do
      # Test without authentication
      get "/positions"
      expect(response).to have_http_status(:unauthorized)

      get "/positions/BIP-20DEC30-CDE/edit"
      expect(response).to have_http_status(:unauthorized)

      post "/positions/BIP-20DEC30-CDE/close"
      expect(response).to have_http_status(:unauthorized)

      patch "/positions/BIP-20DEC30-CDE"
      expect(response).to have_http_status(:unauthorized)
    end

    it "accepts valid basic authentication" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get "/positions", headers: {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:password123")}
      expect(response).to have_http_status(:success)
    end

    it "rejects invalid basic authentication" do
      get "/positions", headers: {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:wrongpassword")}
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /positions" do
    before do
      @auth_header = {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:password123")}
    end

    it "displays positions list successfully" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get "/positions", headers: @auth_header

      expect(response).to have_http_status(:success)
      expect(response.body).to include("BIP-20DEC30-CDE")
      expect(response.body).to include("LONG")
      expect(response.body).to include("2")
      expect(response.body).to include("119900")
      expect(response.body).to include("18.1")
    end

    it "displays empty state when no positions" do
      allow(positions_service).to receive(:list_open_positions).and_return([])

      get "/positions", headers: @auth_header

      expect(response).to have_http_status(:success)
      expect(response.body).to include("No open positions")
    end

    it "displays error message when service fails" do
      allow(positions_service).to receive(:list_open_positions).and_raise(
        Faraday::ClientError.new("API Error", response: {status: 500, body: "Server Error"})
      )

      get "/positions", headers: @auth_header

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Error:")
      expect(response.body).to include("API Error")
    end

    it "displays notice messages" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get "/positions?notice=Position+closed+successfully", headers: @auth_header

      expect(response.body).to include("Position closed successfully")
    end

    it "includes proper HTML structure and styling" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get "/positions", headers: @auth_header

      expect(response.body).to include("<table")
      expect(response.body).to include("<thead>")
      expect(response.body).to include("<tbody>")
      expect(response.body).to include("Product")
      expect(response.body).to include("Side")
      expect(response.body).to include("Size")
      expect(response.body).to include("Current Price")
      expect(response.body).to include("Entry Price")
      expect(response.body).to include("Unrealized P&L")
      expect(response.body).to include("Actions")
    end
  end

  describe "GET /positions/:product_id/edit" do
    before do
      @auth_header = {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:password123")}
    end

    it "displays position edit form successfully" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get "/positions/BIP-20DEC30-CDE/edit", headers: @auth_header

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Position Details")
      expect(response.body).to include("BIP-20DEC30-CDE")
      expect(response.body).to include("LONG")
      expect(response.body).to include("2")
      expect(response.body).to include("119900")
      expect(response.body).to include("118995")
      expect(response.body).to include("18.1")
    end

    it "creates placeholder position when product not found" do
      allow(positions_service).to receive(:list_open_positions).and_return([])

      get "/positions/NONEXISTENT/edit", headers: @auth_header

      expect(response).to have_http_status(:success)
      expect(response.body).to include("NONEXISTENT")
    end

    it "displays error message when service fails" do
      allow(positions_service).to receive(:list_open_positions).and_raise(
        Faraday::ClientError.new("API Error", response: {status: 500, body: "Server Error"})
      )

      get "/positions/BIP-20DEC30-CDE/edit", headers: @auth_header

      expect(response).to have_http_status(:success)
      expect(response.body).to include("API Error")
      expect(response.body).to include("API Error")
    end

    it "includes close position form" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get "/positions/BIP-20DEC30-CDE/edit", headers: @auth_header

      expect(response.body).to include("Close Position")
      expect(response.body).to include("action=\"/positions/BIP-20DEC30-CDE/close\"")
      expect(response.body).to include("method=\"post\"")
      expect(response.body).to include("name=\"size\"")
      expect(response.body).to include("Submit Close")
    end

    it "includes proper styling and layout" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get "/positions/BIP-20DEC30-CDE/edit", headers: @auth_header

      expect(response.body).to include("background: #f8f9fa")
      expect(response.body).to include("color: #28a745")
      expect(response.body).to include("background: #dc3545")
    end
  end

  describe "POST /positions/:product_id/close" do
    before do
      @auth_header = {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:password123")}
    end

    it "closes position successfully and redirects" do
      mock_result = {"success" => true, "order_id" => "close-123"}
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      post "/positions/BIP-20DEC30-CDE/close",
        params: {size: "1"},
        headers: @auth_header

      expect(response).to redirect_to("/positions?notice=Close+order+submitted%3A+close-123")
    end

    it "closes position without size parameter" do
      mock_result = {"success" => true, "message" => "Position closed"}
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      post "/positions/BIP-20DEC30-CDE/close", headers: @auth_header

      expect(response).to redirect_to("/positions?notice=Close+order+submitted%3A+Position+closed")
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:close_position).and_raise(
        StandardError.new("Order failed")
      )

      post "/positions/BIP-20DEC30-CDE/close",
        params: {size: "1"},
        headers: @auth_header

      expect(response).to redirect_to("/positions/BIP-20DEC30-CDE/edit?notice=Error%3A+Order+failed")
    end

    it "passes correct parameters to service" do
      expect(positions_service).to receive(:close_position).with(
        product_id: "BIP-20DEC30-CDE",
        size: "1.5"
      ).and_return({"success" => true})

      post "/positions/BIP-20DEC30-CDE/close",
        params: {size: "1.5"},
        headers: @auth_header
    end
  end

  describe "PATCH /positions/:product_id" do
    before do
      @auth_header = {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:password123")}
    end

    it "updates position successfully and redirects" do
      mock_result = {"success" => true, "order_id" => "update-123"}
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      patch "/positions/BIP-20DEC30-CDE",
        params: {size: "1"},
        headers: @auth_header

      expect(response).to redirect_to("/positions?notice=Close+order+submitted%3A+update-123")
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:close_position).and_raise(
        StandardError.new("Update failed")
      )

      patch "/positions/BIP-20DEC30-CDE",
        params: {size: "1"},
        headers: @auth_header

      expect(response).to redirect_to("/positions/BIP-20DEC30-CDE/edit?notice=Error%3A+Update+failed")
    end
  end

  describe "form submission workflow" do
    before do
      @auth_header = {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:password123")}
    end

    it "completes full position close workflow" do
      # 1. Get positions list
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)
      get "/positions", headers: @auth_header
      expect(response).to have_http_status(:success)

      # 2. Get edit form
      get "/positions/BIP-20DEC30-CDE/edit", headers: @auth_header
      expect(response).to have_http_status(:success)
      expect(response.body).to include("action=\"/positions/BIP-20DEC30-CDE/close\"")

      # 3. Submit close form
      mock_result = {"success" => true, "order_id" => "workflow-123"}
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      post "/positions/BIP-20DEC30-CDE/close",
        params: {size: "1"},
        headers: @auth_header

      expect(response).to redirect_to("/positions?notice=Close+order+submitted%3A+workflow-123")

      # 4. Verify redirect shows success message
      # Note: follow_redirect! doesn't maintain auth headers, so we just verify the redirect
      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions")
      expect(response.redirect_url).to include("workflow-123")
    end
  end

  describe "error handling" do
    before do
      @auth_header = {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:password123")}
    end

    it "handles malformed requests gracefully" do
      # Test with invalid product ID - mock the service to return empty results
      allow(positions_service).to receive(:list_open_positions).with(product_id: "invalid product").and_return([])

      get "/positions/invalid%20product/edit", headers: @auth_header
      expect(response).to have_http_status(:success)
    end

    it "handles missing parameters gracefully" do
      allow(positions_service).to receive(:close_position).and_return({"success" => true})

      # Test close without size parameter
      post "/positions/BIP-20DEC30-CDE/close", headers: @auth_header
      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions")
      expect(response.redirect_url).to include("notice=")
    end
  end

  describe "security" do
    it "prevents access without authentication" do
      get "/positions"
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include("Basic")
    end

    it "validates authentication on every request" do
      # First request with valid auth
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)
      get "/positions", headers: {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("admin:password123")}
      expect(response).to have_http_status(:success)

      # Second request without auth should fail
      get "/positions"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
