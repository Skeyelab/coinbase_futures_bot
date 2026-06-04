# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coinbase::AdvancedTradeClient do
  let(:client) { described_class.new }
  let(:mock_conn) { instance_double(Faraday::Connection) }
  let(:mock_response) { instance_double(Faraday::Response) }

  before do
    allow(Faraday).to receive(:new).and_return(mock_conn)
    allow(mock_conn).to receive(:headers).and_return({})
    allow(mock_conn).to receive(:get).and_return(mock_response)
    allow(mock_conn).to receive(:post).and_return(mock_response)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:debug)
    allow(Rails.logger).to receive(:error)
  end

  describe "#authenticated?" do
    context "when credentials are loaded" do
      before do
        allow(client).to receive(:load_credentials_from_file).and_return(
          {api_key: "key", private_key: "secret"}
        )
        client.instance_variable_set(:@authenticated, true)
      end

      it "returns true" do
        expect(client.authenticated?).to be true
      end
    end

    context "when credentials are absent" do
      before { client.instance_variable_set(:@authenticated, false) }

      it "returns false" do
        expect(client.authenticated?).to be false
      end
    end

    it "does not expose @authenticated via instance_variable_get in callers" do
      expect { client.authenticated? }.not_to raise_error
    end
  end

  describe "#market_price" do
    let(:product_id) { "BIT-26JUN26-CDE" }

    before do
      client.instance_variable_set(:@authenticated, true)
      allow(client).to receive(:authenticated_get).and_return(mock_response)
    end

    context "when order book has bids and asks" do
      before do
        allow(mock_response).to receive(:body).and_return({
          "pricebook" => {
            "bids" => [{"price" => "60100.0"}],
            "asks" => [{"price" => "60200.0"}]
          }
        }.to_json)
      end

      it "returns the mid-market price" do
        expect(client.market_price(product_id)).to eq(60150.0)
      end

      it "calls the product_book endpoint" do
        client.market_price(product_id)
        expect(client).to have_received(:authenticated_get)
          .with("/api/v3/brokerage/market/product_book", hash_including(product_id: product_id))
      end
    end

    context "when order book is empty" do
      before do
        allow(mock_response).to receive(:body).and_return({"pricebook" => {"bids" => [], "asks" => []}}.to_json)
      end

      it "returns nil" do
        expect(client.market_price(product_id)).to be_nil
      end
    end

    context "when the API raises" do
      before { allow(client).to receive(:authenticated_get).and_raise("network error") }

      it "returns nil and logs the error" do
        expect(client.market_price(product_id)).to be_nil
        expect(Rails.logger).to have_received(:error).with(/market_price failed/)
      end
    end

    context "when not authenticated" do
      before { client.instance_variable_set(:@authenticated, false) }

      it "returns nil and logs an error" do
        expect(client.market_price(product_id)).to be_nil
        expect(Rails.logger).to have_received(:error).with(/market_price failed/)
      end
    end
  end

  describe "#get_futures_balance_summary" do
    before do
      client.instance_variable_set(:@authenticated, true)
      allow(client).to receive(:authenticated_get).and_return(mock_response)
      allow(mock_response).to receive(:body).and_return({"futures_buying_power" => "5000"}.to_json)
    end

    it "calls the balance_summary endpoint" do
      client.get_futures_balance_summary
      expect(client).to have_received(:authenticated_get).with("/api/v3/brokerage/cfm/balance_summary")
    end

    it "returns parsed JSON" do
      result = client.get_futures_balance_summary
      expect(result["futures_buying_power"]).to eq("5000")
    end
  end

  describe "#list_futures_positions" do
    before do
      client.instance_variable_set(:@authenticated, true)
      allow(client).to receive(:authenticated_get).and_return(mock_response)
      allow(mock_response).to receive(:body).and_return({"positions" => []}.to_json)
      allow(SentryHelper).to receive(:add_breadcrumb)
    end

    it "calls the cfm/positions endpoint" do
      client.list_futures_positions
      expect(client).to have_received(:authenticated_get).with("/api/v3/brokerage/cfm/positions", {})
    end

    it "returns an array" do
      expect(client.list_futures_positions).to eq([])
    end
  end
end
