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

      get :edit, params: {product_id: "BIP-20DEC30-CDE"}
      expect(response).to have_http_status(:unauthorized)

      post :close, params: {product_id: "BIP-20DEC30-CDE"}
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
      DryRun.disable!(confirm: "LIVE", reason: "spec setup")
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
        Faraday::ClientError.new("API Error", response: {status: 500, body: "Server Error"})
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

      get :index, params: {notice: "Position closed successfully"}

      expect(assigns(:notice_message)).to eq("Position closed successfully")
    end
  end

  describe "GET #index in dry-run (paper) mode" do
    before do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")
      DryRun.enable!
    end

    it "shows paper positions from the DB, not the live Coinbase account" do
      create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG", size: 2, entry_price: 100.0,
        paper: true, status: "OPEN")
      expect(positions_service).not_to receive(:list_open_positions)

      get :index

      expect(assigns(:dry_run)).to be(true)
      row = assigns(:positions).first
      expect(row).to include("product_id" => "BIT-29AUG25-CDE", "side" => "LONG")
      expect(row["avg_entry_price"]).to eq(100.0)
    end

    it "excludes live (non-paper) positions" do
      create(:position, product_id: "BIT-29AUG25-CDE", paper: false, status: "OPEN")

      get :index

      expect(assigns(:positions)).to eq([])
    end
  end

  describe "GET #edit" do
    before do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")
    end

    it "shows position details for existing position" do
      allow(positions_service).to receive(:list_open_positions).and_return(mock_positions)

      get :edit, params: {product_id: "BIP-20DEC30-CDE"}

      expect(response).to have_http_status(:success)
      expect(assigns(:position)).to eq(mock_positions.first)
      expect(response).to render_template(:edit)
    end

    it "creates placeholder position when product not found" do
      allow(positions_service).to receive(:list_open_positions).and_return([])

      get :edit, params: {product_id: "NONEXISTENT"}

      expect(response).to have_http_status(:success)
      expect(assigns(:position)["product_id"]).to eq("NONEXISTENT")
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:list_open_positions).and_raise(
        Faraday::ClientError.new("API Error", response: {status: 500, body: "Server Error"})
      )

      get :edit, params: {product_id: "BIP-20DEC30-CDE"}

      expect(response).to have_http_status(:success)
      expect(assigns(:error_message)).to include("API Error")
      expect(assigns(:position)["product_id"]).to eq("BIP-20DEC30-CDE")
    end

    it "handles general errors gracefully" do
      allow(positions_service).to receive(:list_open_positions).and_raise(StandardError.new("Unexpected error"))

      get :edit, params: {product_id: "BIP-20DEC30-CDE"}

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
      mock_result = {"success" => true, "order_id" => "close-123"}
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      post :close, params: {product_id: "BIP-20DEC30-CDE", size: "1"}

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("close-123")
    end

    it "closes position without size (uses inferred size)" do
      mock_result = {"success" => true, "message" => "Position closed"}
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      post :close, params: {product_id: "BIP-20DEC30-CDE"}

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("Position+closed")
    end

    # A close from the web UI is still an exit and must feed the protections
    # layer (ADR 0003) exactly as a bot-initiated exit does. Closing through
    # Trading::CoinbasePositions directly skipped the cooldown, the stoploss
    # guard, and the daily loss caps.
    it "records a cooldown when closing a tracked position in full" do
      create(:position, product_id: "BIP-20DEC30-CDE", status: "OPEN")
      allow(positions_service).to receive(:close_position).and_return({"success" => true})

      post :close, params: {product_id: "BIP-20DEC30-CDE"}

      cooled = Trading::ProtectionLock.active.select { |l| l["symbol"] == "BIP-20DEC30-CDE" }
      expect(cooled).not_to be_empty
      expect(cooled.first["source"]).to eq("CooldownPeriod")
    ensure
      Trading::ProtectionLock.clear!
    end

    # A PARTIAL reduce realizes P&L too, so it takes the same funnel: the
    # position stays OPEN with fewer contracts, and the protections layer still
    # sees the exit.
    it "reduces a tracked position and records a cooldown on a partial close" do
      create(:position, product_id: "BIP-20DEC30-CDE", status: "OPEN", size: 3.0)
      allow(positions_service).to receive(:close_position).and_return({"success" => true})

      post :close, params: {product_id: "BIP-20DEC30-CDE", size: "1"}

      remaining = Position.open.find_by(product_id: "BIP-20DEC30-CDE")
      expect(remaining.size).to eq(2.0)
      expect(Position.closed.by_product("BIP-20DEC30-CDE").sum(:size)).to eq(1.0)

      cooled = Trading::ProtectionLock.active.select { |l| l["symbol"] == "BIP-20DEC30-CDE" }
      expect(cooled).not_to be_empty
    ensure
      Trading::ProtectionLock.clear!
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:close_position).and_raise(
        StandardError.new("Order failed")
      )

      post :close, params: {product_id: "BIP-20DEC30-CDE", size: "1"}

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions/BIP-20DEC30-CDE/edit")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("Order+failed")
    end

    it "passes correct parameters to service" do
      expect(positions_service).to receive(:close_position).with(
        product_id: "BIP-20DEC30-CDE",
        size: "1.5"
      ).and_return({"success" => true})

      post :close, params: {product_id: "BIP-20DEC30-CDE", size: "1.5"}
    end
  end

  # An increase mutates a tracked row's size and averaged entry price, so the
  # operator UI has to name the row the same way a close does. Handing the
  # service a bare product_id made it re-find one, and with several open on the
  # product it grew whichever sorted last.
  describe "POST #increase" do
    before do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")
    end

    it "passes the tracked open row to the service" do
      position = create(:position, product_id: "BIP-20DEC30-CDE", status: "OPEN")

      expect(positions_service).to receive(:increase_position).with(
        product_id: "BIP-20DEC30-CDE",
        size: "1",
        position: position
      ).and_return({"success" => true, "order_id" => "inc-123"})

      post :increase, params: {product_id: "BIP-20DEC30-CDE", size: "1"}

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("inc-123")
    end

    # Two open rows means the operator's intent is genuinely unknown. We pass
    # nothing rather than pick one; the service then refuses instead of growing
    # a position at random.
    it "resolves nothing when several rows are open on the product" do
      create(:position, product_id: "BIP-20DEC30-CDE", status: "OPEN", entry_time: 2.hours.ago)
      create(:position, product_id: "BIP-20DEC30-CDE", status: "OPEN", entry_time: 1.hour.ago)

      expect(positions_service).to receive(:increase_position).with(
        product_id: "BIP-20DEC30-CDE",
        size: "1",
        position: nil
      ).and_return({"success" => true})

      post :increase, params: {product_id: "BIP-20DEC30-CDE", size: "1"}
    end

    it "reports a refusal back to the operator instead of redirecting as success" do
      allow(positions_service).to receive(:increase_position).and_raise(
        Trading::CoinbasePositions::AmbiguousPositionError.new("2 open positions tracked")
      )

      post :increase, params: {product_id: "BIP-20DEC30-CDE", size: "1"}

      expect(response.redirect_url).to include("/positions/BIP-20DEC30-CDE/edit")
      expect(response.redirect_url).to include("2+open+positions+tracked")
    end
  end

  describe "PATCH #update" do
    before do
      request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64.strict_encode64("admin:password123")
    end

    it "updates position successfully and redirects with notice" do
      mock_result = {"success" => true, "order_id" => "update-123"}
      allow(positions_service).to receive(:close_position).and_return(mock_result)

      patch :update, params: {product_id: "BIP-20DEC30-CDE", size: "1"}

      expect(response).to have_http_status(:redirect)
      expect(response.redirect_url).to include("/positions")
      expect(response.redirect_url).to include("notice=")
      expect(response.redirect_url).to include("update-123")
    end

    it "handles service errors gracefully" do
      allow(positions_service).to receive(:close_position).and_raise(
        StandardError.new("Update failed")
      )

      patch :update, params: {product_id: "BIP-20DEC30-CDE", size: "1"}

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
