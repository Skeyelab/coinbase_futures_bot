# frozen_string_literal: true

namespace :real_time do
  desc "Set up BTC-USD and ETH-USD pairs for real-time monitoring"
  task setup_pairs: :environment do
    puts "Setting up BTC-USD and ETH-USD pairs for real-time monitoring..."

    # Create or update BTC-USD spot pair
    btc_pair = TradingPair.find_or_create_by(product_id: "BTC-USD") do |pair|
      pair.base_currency = "BTC"
      pair.quote_currency = "USD"
      pair.enabled = true
      pair.min_size = 0.00001
      pair.price_increment = 0.01
      pair.size_increment = 0.00001
      pair.status = "online"
    end

    puts "✓ BTC-USD pair: #{btc_pair.product_id} (enabled: #{btc_pair.enabled})"

    # Create or update ETH-USD spot pair
    eth_pair = TradingPair.find_or_create_by(product_id: "ETH-USD") do |pair|
      pair.base_currency = "ETH"
      pair.quote_currency = "USD"
      pair.enabled = true
      pair.min_size = 0.001
      pair.price_increment = 0.01
      pair.size_increment = 0.001
      pair.status = "online"
    end

    puts "✓ ETH-USD pair: #{eth_pair.product_id} (enabled: #{eth_pair.enabled})"

    # Update futures contracts
    puts "Updating futures contracts..."
    contract_manager = MarketData::FuturesContractManager.new
    contract_manager.update_all_contracts

    puts "✓ Futures contracts updated"

    # Verify setup
    puts "\nCurrent trading pairs:"
    TradingPair.enabled.each do |pair|
      contract_type = ""
      if pair.expiration_date
        if pair.current_month?
          contract_type = " (current month)"
        elsif pair.upcoming_month?
          contract_type = " (upcoming month)"
        end
      end
      puts "  #{pair.product_id} - #{pair.base_currency}/#{pair.quote_currency}#{contract_type}"
    end

    puts "\nReal-time monitoring setup complete!"
  end

  desc "Start real-time monitoring for BTC-USD and ETH-USD"
  task start: :environment do
    puts "Starting real-time monitoring for BTC-USD and ETH-USD..."

    # Verify pairs exist
    unless TradingPair.find_by(product_id: "BTC-USD")&.enabled?
      puts "ERROR: BTC-USD pair not found or not enabled. Run 'rake real_time:setup_pairs' first."
      exit 1
    end

    unless TradingPair.find_by(product_id: "ETH-USD")&.enabled?
      puts "ERROR: ETH-USD pair not found or not enabled. Run 'rake real_time:setup_pairs' first."
      exit 1
    end

    # Start real-time monitoring job
    if ENV["INLINE"] == "1"
      puts "Starting inline real-time monitoring..."
      RealTimeMonitoringJob.perform_now(product_ids: %w[BTC-USD ETH-USD])
    else
      puts "Enqueueing real-time monitoring job..."
      RealTimeMonitoringJob.perform_later(product_ids: %w[BTC-USD ETH-USD])
      puts "✓ Real-time monitoring job enqueued"
    end
  end

  desc "Stop all real-time monitoring jobs"
  task stop: :environment do
    puts "Stopping real-time monitoring jobs..."

    # Cancel any pending real-time monitoring jobs
    cancelled_jobs = GoodJob::Job.where(job_class: "RealTimeMonitoringJob", finished_at: nil).count
    GoodJob::Job.where(job_class: "RealTimeMonitoringJob", finished_at: nil).update_all(finished_at: Time.current)

    puts "✓ Cancelled #{cancelled_jobs} real-time monitoring jobs"
  end

  desc "Check real-time monitoring status"
  task status: :environment do
    puts "Real-time monitoring status:"
    puts

    # Check trading pairs
    btc_pair = TradingPair.find_by(product_id: "BTC-USD")
    eth_pair = TradingPair.find_by(product_id: "ETH-USD")

    puts "Trading Pairs:"
    puts "  BTC-USD: #{if btc_pair
                         btc_pair.enabled? ? "✓ enabled" : "✗ disabled"
                       else
                         "✗ not found"
                       end}"
    puts "  ETH-USD: #{if eth_pair
                         eth_pair.enabled? ? "✓ enabled" : "✗ disabled"
                       else
                         "✗ not found"
                       end}"
    puts

    # Check active jobs
    active_rtm_jobs = GoodJob::Job.where(job_class: "RealTimeMonitoringJob", finished_at: nil).count
    active_signal_jobs = GoodJob::Job.where(job_class: "RapidSignalEvaluationJob", finished_at: nil).count

    puts "Active Jobs:"
    puts "  Real-time monitoring: #{active_rtm_jobs}"
    puts "  Rapid signal evaluation: #{active_signal_jobs}"
    puts

    # Check recent activity
    recent_ticks = Tick.where("observed_at > ?", 5.minutes.ago).group(:product_id).count
    puts "Recent Tick Data (last 5 minutes):"
    if recent_ticks.any?
      recent_ticks.each do |product_id, count|
        puts "  #{product_id}: #{count} ticks"
      end
    else
      puts "  No recent tick data"
    end
    puts

    # Check open positions
    open_positions = Position.open.group(:product_id).count
    puts "Open Positions:"
    if open_positions.any?
      open_positions.each do |product_id, count|
        puts "  #{product_id}: #{count} positions"
      end
    else
      puts "  No open positions"
    end
  end

  desc "Test real-time monitoring with sample data"
  task test: :environment do
    puts "Testing real-time monitoring with sample data..."

    # Create sample tick data
    sample_ticks = [
      {product_id: "BTC-USD", price: 45_000.00, observed_at: Time.current},
      {product_id: "ETH-USD", price: 3200.00, observed_at: Time.current},
      {product_id: "BTC-USD", price: 45_050.00, observed_at: Time.current + 1.minute},
      {product_id: "ETH-USD", price: 3210.00, observed_at: Time.current + 1.minute}
    ]

    sample_ticks.each do |tick_data|
      Tick.create!(tick_data)
      puts "✓ Created sample tick: #{tick_data[:product_id]} at $#{tick_data[:price]}"
    end

    # Test rapid signal evaluation
    puts "\nTesting rapid signal evaluation..."
    RapidSignalEvaluationJob.perform_now(
      product_id: "BTC-USD",
      current_price: 45_050.00,
      asset: "BTC"
    )

    puts "✓ Test completed"
  end

  desc "Configure real-time monitoring capacity for ~10 ETH contracts"
  task configure_capacity: :environment do
    puts "Configuring system for ~10 ETH contracts trading capacity..."

    # Update environment configuration
    capacity_config = {
      "SIGNAL_EQUITY_USD" => "25000",           # $25k equity for ~10 ETH contracts
      "MAX_ETH_CONTRACTS" => "10",              # Target ETH capacity (reduced from 20)
      "MAX_BTC_CONTRACTS" => "5",               # Equivalent BTC capacity (reduced from 10)
      "MAX_CONCURRENT_ETH_POSITIONS" => "3",    # Max concurrent ETH positions (reduced from 5)
      "MAX_CONCURRENT_BTC_POSITIONS" => "2",    # Max concurrent BTC positions (reduced from 3)
      "BASIS_ARBITRAGE_THRESHOLD_BPS" => "50",  # 50 bps arbitrage threshold
      "BASIS_EXTREME_THRESHOLD_BPS" => "200",   # 200 bps extreme basis threshold
      "MAX_ARBITRAGE_POSITIONS" => "2"          # Max arbitrage positions
    }

    puts "Recommended environment configuration:"
    capacity_config.each do |key, value|
      puts "  #{key}=#{value}"
    end

    puts "\nTo apply these settings, add them to your .env file or environment variables."
    puts "Current ETH contract capacity: ~#{calculate_current_eth_capacity} contracts"
  end

  private

  def calculate_current_eth_capacity
    equity = ENV.fetch("SIGNAL_EQUITY_USD", "10000").to_f
    eth_price = 3200.0 # Approximate ETH price # $10 per ETH contract
    risk_fraction = 0.005 # 0.5% risk per trade

    max_risk = equity * risk_fraction
    contracts_per_trade = (max_risk / (eth_price * 0.003)).floor # 30 bps stop loss
    [contracts_per_trade * 3, 10].min # 3 concurrent positions, max 10 (reduced from 5 and 20)
  end
end
