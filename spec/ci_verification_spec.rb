# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CI Environment Verification", :ci_only do
  before(:all) do
    puts "=== CI VERIFICATION TEST STARTING ==="
  end

  it "has real database connectivity" do
    puts "Rails environment: #{Rails.env}"
    puts "Database: #{ActiveRecord::Base.connection.current_database}"

    expect(ActiveRecord::Base.connection).to be_active
    expect(ActiveRecord::Base.connection.current_database).to include("test")
    puts "✅ Database connectivity verified"
  end

  it "can perform real database operations" do
    initial_count = Position.count

    expect do
      Position.create!(
        product_id: "CI-TEST-USD",
        side: "LONG", # Use uppercase enum value
        size: 1.0,
        entry_price: 50_000.0,
        entry_time: Time.current,
        status: "OPEN", # Use uppercase enum value
        day_trading: false
      )
    end.to change { Position.count }.by(1)

    # Verify the record was created
    position = Position.last
    expect(position.product_id).to eq("CI-TEST-USD")
    expect(position.side).to eq("LONG")
    expect(position.status).to eq("OPEN")

    # Clean up - destroy the test record
    expect { position.destroy! }.to change { Position.count }.by(-1)
    expect(Position.count).to eq(initial_count)

    puts "✅ Real database operations verified"
  end

  it "can create and destroy TradingPair records" do
    initial_count = TradingPair.count

    expect do
      TradingPair.create!(
        product_id: "CI-TEST-USD",
        base_currency: "CI",
        quote_currency: "USD",
        status: "active",
        contract_type: "futures",
        expiration_date: 1.month.from_now,
        min_size: 0.001,
        price_increment: 0.01,
        size_increment: 0.001
      )
    end.to change { TradingPair.count }.by(1)

    # Verify the record was created
    pair = TradingPair.last
    expect(pair.product_id).to eq("CI-TEST-USD")
    expect(pair.base_currency).to eq("CI")
    expect(pair.quote_currency).to eq("USD")

    # Clean up - destroy the test record
    expect { pair.destroy! }.to change { TradingPair.count }.by(-1)
    expect(TradingPair.count).to eq(initial_count)

    puts "✅ TradingPair operations verified"
  end

  it "can access test files" do
    expect(File.exist?("spec/ci_verification_spec.rb")).to be true
    expect(File.exist?("app/models/position.rb")).to be true
    expect(File.exist?("app/models/trading_pair.rb")).to be true
    puts "✅ Test file access verified"
  end

  it "has test effectiveness module loaded" do
    expect(defined?(TestEffectiveness)).to eq("constant")
    puts "✅ Test effectiveness module loaded"
  end

  it "can perform basic ActiveRecord operations" do
    # Test basic database operations
    expect(ActiveRecord::Base.connection).to be_active
    expect(ActiveRecord::Base.connection.tables).to include("positions")
    expect(ActiveRecord::Base.connection.tables).to include("trading_pairs")
    puts "✅ ActiveRecord operations verified"
  end
end
