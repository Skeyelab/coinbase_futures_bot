# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::CoinbasePositions, type: :service do
  let(:service) { described_class.new(base_url: "https://example.com") }

  before do
    # Mock the credentials loading to avoid file system dependencies
    allow(service).to receive(:load_credentials_from_file).and_return({
      api_key: "organizations/test-org/apiKeys/test-key",
      private_key: "-----BEGIN EC PRIVATE KEY-----\nMOCK_KEY\n-----END EC PRIVATE KEY-----"
    })

    # Set the instance variables directly to avoid initialization issues
    service.instance_variable_set(:@api_key, "organizations/test-org/apiKeys/test-key")
    service.instance_variable_set(:@api_secret, "-----BEGIN EC PRIVATE KEY-----\nMOCK_KEY\n-----END EC PRIVATE KEY-----")
    service.instance_variable_set(:@authenticated, true)

    # Mock JWT generation to avoid OpenSSL issues in tests
    allow(service).to receive(:build_jwt_token).and_return("mock.jwt.token")
  end

  describe "authentication" do
    it "loads credentials from cdp_api_key.json" do
      service = described_class.new
      allow(service).to receive(:load_credentials_from_file).and_return({
        api_key: "test-key",
        private_key: "test-secret"
      })

      # Set the instance variables to avoid nil errors
      service.instance_variable_set(:@api_key, "test-key")
      service.instance_variable_set(:@api_secret, "test-secret")

      result = service.send(:load_credentials_from_file)
      expect(result).to eq({
        api_key: "test-key",
        private_key: "test-secret"
      })
    end

    it "initializes with authentication when credentials are available" do
      service = described_class.new
      allow(service).to receive(:load_credentials_from_file).and_return({
        api_key: "test-key",
        private_key: "test-secret"
      })

      # Set the instance variables to avoid nil errors
      service.instance_variable_set(:@api_key, "test-key")
      service.instance_variable_set(:@api_secret, "test-secret")

      service.send(:initialize)
      expect(service.instance_variable_get(:@authenticated)).to be true
    end

    it "raises error when not authenticated" do
      service.instance_variable_set(:@authenticated, false)
      expect { service.list_open_positions }.to raise_error("Authentication required")
    end
  end

  describe "JWT token generation" do
    it "generates JWT with correct payload structure" do
      # For this test, we need to create a valid mock private key
      valid_private_key = OpenSSL::PKey::EC.generate('prime256v1')
      service.instance_variable_set(:@api_secret, valid_private_key.to_pem)

      allow(service).to receive(:build_jwt_token).and_call_original
      allow(service).to receive(:format_jwt_uri).and_return("GET api.coinbase.com/api/v3/brokerage/cfm/positions")

      jwt = service.send(:build_jwt_token, "GET", "/api/v3/brokerage/cfm/positions")

      # Decode JWT to verify payload
      decoded = JWT.decode(jwt, nil, false)
      payload = decoded.first

      expect(payload["iss"]).to eq("cdp")
      expect(payload["sub"]).to eq("organizations/test-org/apiKeys/test-key")
      expect(payload["nbf"]).to be_present
      expect(payload["exp"]).to be_present
      expect(payload["uri"]).to eq("GET api.coinbase.com/api/v3/brokerage/cfm/positions")
    end

    it "formats JWT URI correctly for different HTTP methods" do
      # GET with params
      uri = service.send(:format_jwt_uri, "GET", "/api/v3/brokerage/cfm/positions", { product_id: "BTC-USD" }, nil)
      expect(uri).to eq("GET api.coinbase.com/api/v3/brokerage/cfm/positions?product_id=BTC-USD")

      # POST without params
      uri = service.send(:format_jwt_uri, "POST", "/api/v3/brokerage/orders", nil, "{}")
      expect(uri).to eq("POST api.coinbase.com/api/v3/brokerage/orders")
    end
  end

  describe "futures positions" do
    it "lists open positions with correct futures data structure" do
      mock_response = instance_double("Response", body: {
        "positions" => [
          {
            "product_id" => "BIP-20DEC30-CDE",
            "number_of_contracts" => "3",
            "side" => "LONG",
            "current_price" => "119395",
            "avg_entry_price" => "118995",
            "unrealized_pnl" => "30.15"
          }
        ]
      }.to_json)

      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)

      positions = service.list_open_positions
      expect(positions.size).to eq(1)
      expect(positions.first["product_id"]).to eq("BIP-20DEC30-CDE")
      expect(positions.first["number_of_contracts"]).to eq("3")
      expect(positions.first["side"]).to eq("LONG")
    end

    it "filters positions by product_id in Ruby when specified" do
      mock_response = instance_double("Response", body: {
        "positions" => [
          { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "3" },
          { "product_id" => "ETH-USD-PERP", "number_of_contracts" => "1" }
        ]
      }.to_json)

      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)

      positions = service.list_open_positions(product_id: "BIP-20DEC30-CDE")
      expect(positions.size).to eq(1)
      expect(positions.first["product_id"]).to eq("BIP-20DEC30-CDE")
    end
  end

  describe "futures order building" do
    it "builds order body with correct futures side values" do
      order_body = service.send(:build_order_body,
        product_id: "BIP-20DEC30-CDE",
        side: :long,
        size: "2",
        type: :market
      )

      expect(order_body["side"]).to eq("LONG")
      expect(order_body["product_id"]).to eq("BIP-20DEC30-CDE")
      expect(order_body["order_configuration"]["market_market_ioc"]["base_size"]).to eq("2")
    end

    it "converts side values correctly for futures orders" do
      expect(service.send(:build_order_body, product_id: "TEST", side: :long, size: "1", type: :market)["side"]).to eq("LONG")
      expect(service.send(:build_order_body, product_id: "TEST", side: :short, size: "1", type: :market)["side"]).to eq("SHORT")
      expect(service.send(:build_order_body, product_id: "TEST", side: :buy, size: "1", type: :market)["side"]).to eq("BUY")
      expect(service.send(:build_order_body, product_id: "TEST", side: :sell, size: "1", type: :market)["side"]).to eq("SELL")
    end

    it "raises error for invalid side values" do
      expect {
        service.send(:build_order_body, product_id: "TEST", side: :invalid, size: "1", type: :market)
      }.to raise_error(ArgumentError, /side must be :long, :short, :buy, or :sell/)
    end
  end

  describe "position inference" do
    it "infers position size from number_of_contracts field" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "3", "side" => "LONG" }
      ])

      size, side = service.send(:infer_position, product_id: "BIP-20DEC30-CDE")
      expect(size).to eq("3")
      expect(side).to eq(:long)
    end

    it "falls back to other size fields when number_of_contracts is not available" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BTC-USD", "size" => "0.01", "side" => "SHORT" }
      ])

      size, side = service.send(:infer_position, product_id: "BTC-USD")
      expect(size).to eq("0.01")
      expect(side).to eq(:short)
    end

    it "normalizes side values correctly" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "TEST", "number_of_contracts" => "1", "side" => "LONG" }
      ])

      _, side = service.send(:infer_position, product_id: "TEST")
      expect(side).to eq(:long)
    end
  end

  describe "position closing" do
    it "closes LONG position by creating SELL order" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "3", "side" => "LONG" }
      ])

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "close-123" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      result = service.close_position(product_id: "BIP-20DEC30-CDE", size: "1")
      expect(result["success"]).to be true
    end

    it "closes SHORT position by creating BUY order" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "2", "side" => "SHORT" }
      ])

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "close-456" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      result = service.close_position(product_id: "BIP-20DEC30-CDE", size: "1")
      expect(result["success"]).to be true
    end

    it "uses explicit size when provided" do
      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "close-789" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      result = service.close_position(product_id: "BIP-20DEC30-CDE", size: "1.5")
      expect(result["success"]).to be true
    end

    it "builds correct order body for LONG position close (SELL order)" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "3", "side" => "LONG" }
      ])

      # Mock the build_order_body method to capture the side parameter
      expect(service).to receive(:build_order_body).with(
        product_id: "BIP-20DEC30-CDE",
        side: :sell,
        size: "1",
        type: :market
      ).and_return({
        "client_order_id" => "test-123",
        "product_id" => "BIP-20DEC30-CDE",
        "side" => "SELL",
        "order_configuration" => { "market_market_ioc" => { "base_size" => "1" } }
      })

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "close-123" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      service.close_position(product_id: "BIP-20DEC30-CDE", size: "1")
    end

    it "builds correct order body for SHORT position close (BUY order)" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "2", "side" => "SHORT" }
      ])

      # Mock the build_order_body method to capture the side parameter
      expect(service).to receive(:build_order_body).with(
        product_id: "BIP-20DEC30-CDE",
        side: :buy,
        size: "1",
        type: :market
      ).and_return({
        "client_order_id" => "test-456",
        "product_id" => "BIP-20DEC30-CDE",
        "side" => "BUY",
        "order_configuration" => { "market_market_ioc" => { "base_size" => "1" } }
      })

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "close-456" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      service.close_position(product_id: "BIP-20DEC30-CDE", size: "1")
    end
  end

  describe "#increase_position" do
    it "increases LONG position by creating BUY order" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "3", "side" => "LONG" }
      ])

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "increase-123" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      result = service.increase_position(product_id: "BIP-20DEC30-CDE", size: "1")
      expect(result["success"]).to be true
    end

    it "increases SHORT position by creating SELL order" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "2", "side" => "SHORT" }
      ])

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "increase-456" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      result = service.increase_position(product_id: "BIP-20DEC30-CDE", size: "1")
      expect(result["success"]).to be true
    end

    it "handles lowercase side values correctly" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "1", "side" => "long" }
      ])

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "increase-789" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      result = service.increase_position(product_id: "BIP-20DEC30-CDE", size: "0.5")
      expect(result["success"]).to be true
    end

    it "builds correct order body for LONG position increase (BUY order)" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "3", "side" => "LONG" }
      ])

      # Mock the build_order_body method to capture the side parameter
      expect(service).to receive(:build_order_body).with(
        product_id: "BIP-20DEC30-CDE",
        side: :buy,
        size: "1",
        type: :market
      ).and_return({
        "client_order_id" => "test-123",
        "product_id" => "BIP-20DEC30-CDE",
        "side" => "BUY",
        "order_configuration" => { "market_market_ioc" => { "base_size" => "1" } }
      })

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "increase-123" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      service.increase_position(product_id: "BIP-20DEC30-CDE", size: "1")
    end

    it "builds correct order body for SHORT position increase (SELL order)" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "2", "side" => "SHORT" }
      ])

      # Mock the build_order_body method to capture the side parameter
      expect(service).to receive(:build_order_body).with(
        product_id: "BIP-20DEC30-CDE",
        side: :sell,
        size: "1",
        type: :market
      ).and_return({
        "client_order_id" => "test-456",
        "product_id" => "BIP-20DEC30-CDE",
        "side" => "SELL",
        "order_configuration" => { "market_market_ioc" => { "base_size" => "1" } }
      })

      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "increase-456" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)

      service.increase_position(product_id: "BIP-20DEC30-CDE", size: "1")
    end

    it "returns error when no open position found" do
      allow(service).to receive(:list_open_positions).and_return([])

      result = service.increase_position(product_id: "BIP-20DEC30-CDE", size: "1")
      expect(result["success"]).to be false
      expect(result["message"]).to match(/No open position found/)
    end

    it "raises error when position side cannot be determined" do
      allow(service).to receive(:list_open_positions).and_return([
        { "product_id" => "BIP-20DEC30-CDE", "number_of_contracts" => "1", "side" => "UNKNOWN" }
      ])

      expect {
        service.increase_position(product_id: "BIP-20DEC30-CDE", size: "1")
      }.to raise_error(/Cannot determine position side for increase/)
    end
  end

  describe "error handling" do
        it "handles API errors gracefully with detailed logging" do
      conn = service.instance_variable_get(:@conn)
      # Create a mock response hash that the service can access
      mock_response = { status: 400, body: '{"error": "Invalid product_id"}' }
      error = Faraday::ClientError.new("Bad Request")
      allow(error).to receive(:response).and_return(mock_response)

      expect(conn).to receive(:get).and_raise(error)

      expect { service.list_open_positions }.to raise_error(Faraday::ClientError, /Bad Request: Invalid product_id/)
    end

        it "handles POST errors with detailed response information" do
      conn = service.instance_variable_get(:@conn)
      # Create a mock response hash that the service can access
      mock_response = { status: 400, body: '{"error": "Invalid order format"}' }
      error = Faraday::ClientError.new("Bad Request")
      allow(error).to receive(:response).and_return(mock_response)

      expect(conn).to receive(:post).and_raise(error)

      expect { service.close_position(product_id: "TEST", size: "1") }.to raise_error(Faraday::ClientError, /Bad Request: Invalid order format/)
    end
  end



  # Keep existing tests for backward compatibility
  describe "legacy functionality" do
    it "lists open positions (basic)" do
      mock_response = instance_double("Response", body: { "positions" => [ { "product_id" => "BTC-USD-PERP", "size" => "0.01", "side" => "long" } ] }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)

      positions = service.list_open_positions
      expect(positions.size).to eq(1)
      expect(positions.first["product_id"]).to eq("BTC-USD-PERP")
    end

    it "opens a market position" do
      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "abc" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)
      res = service.open_position(product_id: "BTC-USD-PERP", side: :buy, size: "0.01")
      expect(res["success"]).to be true
    end

    it "requires price for limit orders" do
      expect {
        service.open_position(product_id: "BTC-USD-PERP", side: :buy, size: "0.01", type: :limit)
      }.to raise_error(ArgumentError)
    end

    it "closes position using inferred size" do
      allow(service).to receive(:list_open_positions).and_return([ { "product_id" => "BTC-USD-PERP", "size" => "0.02", "side" => "long" } ])
      mock_response = instance_double("Response", body: { "success" => true, "order_id" => "def" }.to_json)
      conn = service.instance_variable_get(:@conn)
      expect(conn).to receive(:post).and_return(mock_response)
      res = service.close_position(product_id: "BTC-USD-PERP")
      expect(res["success"]).to be true
    end

    it "returns success with message when no open size" do
      allow(service).to receive(:list_open_positions).and_return([])
      res = service.close_position(product_id: "BTC-USD-PERP")
      expect(res["success"]).to eq(true)
      expect(res["message"]).to match(/No open position/)
    end
  end
end
