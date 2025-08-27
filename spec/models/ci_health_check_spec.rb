# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CI Health Check", type: :model do
  it "can connect to the database" do
    expect { ActiveRecord::Base.connection.execute("SELECT 1") }.not_to raise_error
  end

  it "can create and query a simple record" do
    # Test basic database operations
    test_pair = TradingPair.create!(
      product_id: "TEST-USD",
      base_currency: "TEST",
      quote_currency: "USD",
      enabled: true,
      min_size: 0.001,
      price_increment: 0.01,
      size_increment: 0.001,
      status: "online"
    )
    
    expect(test_pair).to be_persisted
    expect(TradingPair.find_by(product_id: "TEST-USD")).to eq(test_pair)
    
    # Clean up
    test_pair.destroy
  end

  it "can perform basic model operations" do
    expect(TradingPair.count).to be >= 0
    expect(Position.count).to be >= 0
    expect(Tick.count).to be >= 0
  end

  it "has proper database schema" do
    # Verify key tables exist and have expected columns
    expect(ActiveRecord::Base.connection.table_exists?("trading_pairs")).to be true
    expect(ActiveRecord::Base.connection.table_exists?("positions")).to be true
    expect(ActiveRecord::Base.connection.table_exists?("ticks")).to be true
    expect(ActiveRecord::Base.connection.table_exists?("candles")).to be true
  end
end
