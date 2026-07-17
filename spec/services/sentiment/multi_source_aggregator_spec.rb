# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::MultiSourceAggregator, type: :service do
  describe "#source_status" do
    subject(:names) { described_class.new.source_status.map { |s| s[:name] } }

    it "includes the crypto sources" do
      expect(names).to include("cryptopanic", "coindesk_rss", "cointelegraph_rss")
    end

    it "includes an oil news source" do
      expect(names).to include("oilprice_rss")
    end
  end
end
