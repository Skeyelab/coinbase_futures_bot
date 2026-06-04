# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coinbase::Client do
  let(:mock_at) { instance_double(Coinbase::AdvancedTradeClient) }
  let(:mock_ex) { instance_double(Coinbase::ExchangeClient) }

  before do
    allow(Coinbase::AdvancedTradeClient).to receive(:new).and_return(mock_at)
    allow(Coinbase::ExchangeClient).to receive(:new).and_return(mock_ex)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
  end

  subject(:client) { described_class.new }

  describe "#auth_status" do
    it "delegates to authenticated? on each sub-client without reflection" do
      allow(mock_at).to receive(:authenticated?).and_return(true)
      allow(mock_ex).to receive(:authenticated?).and_return(false)

      expect(client.auth_status).to eq({advanced_trade: true, exchange: false})
      expect(mock_at).to have_received(:authenticated?)
      expect(mock_ex).to have_received(:authenticated?)
    end
  end

  describe "#can_access_futures?" do
    it "returns advanced_trade authenticated? without reflection" do
      allow(mock_at).to receive(:authenticated?).and_return(true)
      expect(client.can_access_futures?).to be true
    end
  end

  describe "#can_access_spot_trading?" do
    it "returns exchange authenticated? without reflection" do
      allow(mock_ex).to receive(:authenticated?).and_return(false)
      expect(client.can_access_spot_trading?).to be false
    end
  end
end
