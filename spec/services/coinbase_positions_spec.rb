# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::CoinbasePositions, type: :service do
  let(:service) { described_class.new(base_url: "https://example.com") }

  before do
    @orig_key = ENV["COINBASE_API_KEY"]
    @orig_secret = ENV["COINBASE_API_SECRET"]
    ENV["COINBASE_API_KEY"] = "k"
    ENV["COINBASE_API_SECRET"] = "s"
  end

  after do
    ENV["COINBASE_API_KEY"] = @orig_key
    ENV["COINBASE_API_SECRET"] = @orig_secret
  end

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