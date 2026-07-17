# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::ContractSizeResolver do
  let(:client) { instance_double(Coinbase::AdvancedTradeClient) }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  def product_response(size)
    {"future_product_details" => {"contract_size" => size}}
  end

  describe ".for_product" do
    it "returns the API contract size and caches it" do
      allow(client).to receive(:get_product).with("NOL-19JUN26-CDE").and_return(product_response("10"))

      expect(described_class.for_product("NOL-19JUN26-CDE", client: client)).to eq(10.0)

      # Second call is served from cache — no second API hit.
      described_class.for_product("NOL-19JUN26-CDE", client: client)
      expect(client).to have_received(:get_product).once
    end

    it "returns the default WITHOUT caching it when the API lookup fails" do
      allow(client).to receive(:get_product).and_raise(StandardError, "boom")

      expect(described_class.for_product("NOL-19JUN26-CDE", client: client)).to eq(1)

      # The fallback must not be cached: once the API recovers, the real
      # contract size is returned (not a stale cached 1 that understates
      # NOL PnL/leverage ~10x).
      allow(client).to receive(:get_product).with("NOL-19JUN26-CDE").and_return(product_response("10"))
      expect(described_class.for_product("NOL-19JUN26-CDE", client: client)).to eq(10.0)
    end
  end
end
