# frozen_string_literal: true

RSpec.describe "CI Environment Verification", :ci_only do
  before(:all) do
    puts "=== CI VERIFICATION TEST STARTING ==="
    puts "Rails environment: #{Rails.env}"
    puts "Database: #{ActiveRecord::Base.connection.current_database}"
    puts "Test files found: #{Dir.glob("spec/**/*_spec.rb").count}"
    puts "CI detected: #{ENV["CI"]}"
  end

  it "has real database connectivity" do
    expect(ActiveRecord::Base.connection).to be_active
    expect(ActiveRecord::Base.connection.current_database).to include("test")
    puts "✅ Database connectivity verified"
  end

  it "can perform real database operations" do
    Position.count

    expect do
      Position.create!(
        product_id: "CI-TEST-USD",
        side: "LONG",
        size: 1.0,
        entry_price: 100.0,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: true
      )
    end.to change(Position, :count).by(1)

    # Clean up
    Position.where(product_id: "CI-TEST-USD").destroy_all

    puts "✅ Real database operations verified"
  end

  it "has test effectiveness validation enabled" do
    expect(defined?(TestEffectiveness)).to be_truthy
    puts "✅ Test effectiveness validation loaded"
  end

  it "can access real test files" do
    test_files = Dir.glob("spec/**/*_spec.rb")
    expect(test_files.count).to be > 0
    expect(test_files.first).to end_with("_spec.rb")
    puts "✅ Test file access verified (#{test_files.count} files found)"
  end

  it "has proper test environment variables" do
    expect(ENV["CI"]).to eq("true")
    expect(ENV["RAILS_ENV"]).to eq("test")
    puts "✅ CI environment variables verified"
  end

  it "can create and destroy test data" do
    # Test TradingPair creation
    pair = TradingPair.create!(
      product_id: "CI-TEST-PAIR",
      symbol: "CI-TEST",
      enabled: true,
      contract_type: "futures",
      expiration_date: 1.month.from_now
    )

    expect(pair).to be_persisted
    expect(pair.product_id).to eq("CI-TEST-PAIR")

    # Clean up
    pair.destroy
    expect(TradingPair.find_by(product_id: "CI-TEST-PAIR")).to be_nil

    puts "✅ Test data creation/destruction verified"
  end

  after(:all) do
    puts "=== CI VERIFICATION TEST COMPLETED ==="
    puts "All CI environment checks passed"
  end
end
