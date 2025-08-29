# frozen_string_literal: true

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
        side: "long",
        size: 1.0,
        entry_price: 50000.0,
        entry_time: Time.current,
        status: "open",
        day_trading: false
      )
    end.to change(Position, :count).by(1)

    # Clean up
    Position.where(product_id: "CI-TEST-USD").destroy_all
    expect(Position.count).to eq(initial_count)
    puts "✅ Position CRUD operations verified"
  end

  it "can create and destroy test data" do
    # Test TradingPair creation with correct attributes
    pair = TradingPair.create!(
      product_id: "CI-TEST-PAIR",
      base_currency: "CI",
      quote_currency: "USD",
      status: "active",
      min_size: 0.001,
      price_increment: 0.01,
      size_increment: 0.001,
      enabled: true,
      contract_type: "futures",
      expiration_date: 1.month.from_now
    )

    expect(pair).to be_persisted
    expect(pair.product_id).to eq("CI-TEST-PAIR")
    expect(pair.base_currency).to eq("CI")
    expect(pair.quote_currency).to eq("USD")

    # Clean up
    pair.destroy
    expect(TradingPair.find_by(product_id: "CI-TEST-PAIR")).to be_nil
    puts "✅ TradingPair CRUD operations verified"
  end

  it "can access test files" do
    test_files = Dir.glob("spec/**/*_spec.rb")
    expect(test_files).not_to be_empty
    expect(test_files.first).to include("spec/")
    puts "✅ Test file access verified (#{test_files.count} test files found)"
  end

  it "has test effectiveness module loaded" do
    expect(defined?(TestEffectiveness)).to be_truthy
    puts "✅ TestEffectiveness module loaded"
  end

  it "has proper RSpec configuration" do
    expect(RSpec.configuration).to be_truthy
    puts "✅ RSpec configuration loaded"
  end

  it "can perform database queries" do
    # Test a simple query
    count = TradingPair.count
    expect(count).to be >= 0
    puts "✅ Database queries working (TradingPair count: #{count})"
  end

  it "has proper test environment setup" do
    expect(Rails.env.test?).to be true
    expect(ActiveRecord::Base.connection.current_database).to include("test")
    puts "✅ Test environment properly configured"
  end
end
