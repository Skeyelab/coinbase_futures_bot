# frozen_string_literal: true

namespace :positions do
  desc "Check all positions with type breakdown"
  task check_all: :environment do
    puts "=== Position Monitoring Report ==="
    puts "Generated at: #{Time.current.utc.iso8601}"
    puts

    # Day trading positions
    day_positions = Position.open.day_trading
    puts "Day Trading Positions: #{day_positions.count}"
    if day_positions.any?
      puts "  - Approaching closure (>23h): #{day_positions.where("entry_time < ?", 23.hours.ago).count}"
      puts "  - Needing closure (>24h): #{day_positions.where("entry_time < ?", 24.hours.ago).count}"
      
      avg_duration = day_positions.average("EXTRACT(EPOCH FROM (NOW() - entry_time)) / 3600")
      puts "  - Average duration: #{avg_duration&.round(2)} hours"
      
      total_exposure = calculate_exposure(day_positions)
      puts "  - Total exposure: #{total_exposure.round(2)}%"
    end
    puts

    # Swing trading positions
    swing_positions = Position.open.swing_trading
    puts "Swing Trading Positions: #{swing_positions.count}"
    if swing_positions.any?
      puts "  - Approaching expiry (>13 days): #{swing_positions.where("entry_time < ?", 13.days.ago).count}"
      puts "  - Exceeding max hold (>14 days): #{swing_positions.where("entry_time < ?", 14.days.ago).count}"
      
      avg_duration = swing_positions.average("EXTRACT(EPOCH FROM (NOW() - entry_time)) / 86400")
      puts "  - Average duration: #{avg_duration&.round(2)} days"
      
      total_exposure = calculate_exposure(swing_positions)
      puts "  - Total exposure: #{total_exposure.round(2)}%"
    end
    puts

    # Overall statistics
    total_positions = Position.open.count
    puts "Total Open Positions: #{total_positions}"
    
    daily_pnl = Position.where(entry_time: Date.current.beginning_of_day..Time.current).sum(:pnl)
    puts "Daily PnL: $#{daily_pnl&.round(2)}"
    
    unrealized_pnl = Position.open.sum(:pnl) || 0
    puts "Unrealized PnL: $#{unrealized_pnl.round(2)}"
    
    puts "=== End Report ==="
  end

  desc "Check day trading positions specifically"
  task check_day_trading: :environment do
    puts "=== Day Trading Position Report ==="
    puts "Generated at: #{Time.current.utc.iso8601}"
    puts

    day_positions = Position.open.day_trading
    puts "Total Day Trading Positions: #{day_positions.count}"

    if day_positions.any?
      # Position age analysis
      approaching_closure = day_positions.where("entry_time < ?", 23.hours.ago)
      needing_closure = day_positions.where("entry_time < ?", 24.hours.ago)

      puts "Positions approaching closure (>23h): #{approaching_closure.count}"
      puts "Positions needing closure (>24h): #{needing_closure.count}"

      if needing_closure.any?
        puts "⚠️  URGENT: #{needing_closure.count} positions need immediate closure!"
        needing_closure.each do |pos|
          duration_hours = ((Time.current - pos.entry_time) / 1.hour).round(2)
          puts "  - #{pos.product_id} #{pos.side} (#{duration_hours}h old)"
        end
      end

      # Exposure analysis
      total_exposure = calculate_exposure(day_positions)
      max_exposure = Rails.application.config.monitoring_config[:max_day_trading_exposure] * 100
      
      puts "Total exposure: #{total_exposure.round(2)}%"
      puts "Max allowed: #{max_exposure}%"
      
      if total_exposure > max_exposure
        puts "⚠️  WARNING: Day trading exposure exceeds limit!"
      end

      # Performance analysis
      day_pnl = day_positions.sum(:pnl) || 0
      puts "Day trading unrealized PnL: $#{day_pnl.round(2)}"
      
      avg_duration = day_positions.average("EXTRACT(EPOCH FROM (NOW() - entry_time)) / 3600")
      puts "Average position duration: #{avg_duration&.round(2)} hours"

      # List positions by product
      puts "\nPositions by product:"
      day_positions.group(:product_id).count.each do |product, count|
        puts "  #{product}: #{count} positions"
      end
    else
      puts "No day trading positions currently open."
    end

    puts "=== End Report ==="
  end

  desc "Check swing trading positions specifically"
  task check_swing_trading: :environment do
    puts "=== Swing Trading Position Report ==="
    puts "Generated at: #{Time.current.utc.iso8601}"
    puts

    swing_positions = Position.open.swing_trading
    puts "Total Swing Trading Positions: #{swing_positions.count}"

    if swing_positions.any?
      # Position age analysis
      approaching_expiry = swing_positions.where("entry_time < ?", 13.days.ago)
      exceeding_max = swing_positions.where("entry_time < ?", 14.days.ago)

      puts "Positions approaching expiry (>13 days): #{approaching_expiry.count}"
      puts "Positions exceeding max hold (>14 days): #{exceeding_max.count}"

      if exceeding_max.any?
        puts "⚠️  WARNING: #{exceeding_max.count} positions exceed maximum hold period!"
        exceeding_max.each do |pos|
          duration_days = ((Time.current - pos.entry_time) / 1.day).round(2)
          puts "  - #{pos.product_id} #{pos.side} (#{duration_days} days old)"
        end
      end

      # Exposure analysis
      total_exposure = calculate_exposure(swing_positions)
      max_exposure = Rails.application.config.monitoring_config[:max_swing_trading_exposure] * 100
      
      puts "Total exposure: #{total_exposure.round(2)}%"
      puts "Max allowed: #{max_exposure}%"
      
      if total_exposure > max_exposure
        puts "⚠️  WARNING: Swing trading exposure exceeds limit!"
      end

      # Performance analysis
      swing_pnl = swing_positions.sum(:pnl) || 0
      puts "Swing trading unrealized PnL: $#{swing_pnl.round(2)}"
      
      avg_duration = swing_positions.average("EXTRACT(EPOCH FROM (NOW() - entry_time)) / 86400")
      puts "Average position duration: #{avg_duration&.round(2)} days"

      # List positions by product
      puts "\nPositions by product:"
      swing_positions.group(:product_id).count.each do |product, count|
        puts "  #{product}: #{count} positions"
      end

      # Risk analysis
      puts "\nRisk Analysis:"
      high_duration = swing_positions.where("entry_time < ?", 10.days.ago).count
      puts "  Positions >10 days old: #{high_duration}"
      
      if swing_positions.joins("LEFT JOIN trading_pairs ON positions.product_id = trading_pairs.product_id").where("trading_pairs.expires_at < ?", 7.days.from_now).exists?
        expiring_contracts = swing_positions.joins("LEFT JOIN trading_pairs ON positions.product_id = trading_pairs.product_id").where("trading_pairs.expires_at < ?", 7.days.from_now).count
        puts "  Positions with contracts expiring <7 days: #{expiring_contracts}"
      end
    else
      puts "No swing trading positions currently open."
    end

    puts "=== End Report ==="
  end

  desc "Generate portfolio exposure report"
  task exposure_report: :environment do
    puts "=== Portfolio Exposure Report ==="
    puts "Generated at: #{Time.current.utc.iso8601}"
    puts

    # Calculate exposures
    day_exposure = calculate_exposure(Position.open.day_trading)
    swing_exposure = calculate_exposure(Position.open.swing_trading)
    total_exposure = day_exposure + swing_exposure

    # Get limits from configuration
    config = Rails.application.config.monitoring_config
    max_day_exposure = config[:max_day_trading_exposure] * 100
    max_swing_exposure = config[:max_swing_trading_exposure] * 100

    puts "Day Trading Exposure: #{day_exposure.round(2)}% (max: #{max_day_exposure}%)"
    puts "Swing Trading Exposure: #{swing_exposure.round(2)}% (max: #{max_swing_exposure}%)"
    puts "Total Portfolio Exposure: #{total_exposure.round(2)}%"
    puts

    # Check for warnings
    warnings = []
    warnings << "Day trading exposure exceeds limit" if day_exposure > max_day_exposure
    warnings << "Swing trading exposure exceeds limit" if swing_exposure > max_swing_exposure

    if warnings.any?
      puts "⚠️  WARNINGS:"
      warnings.each { |warning| puts "  - #{warning}" }
    else
      puts "✅ All exposure limits within acceptable ranges"
    end
    puts

    # Margin analysis (if available)
    begin
      client = Coinbase::Client.new
      balance_summary = client.futures_balance_summary
      balance = balance_summary['balance_summary']
      
      puts "Margin Information:"
      puts "  Available margin: $#{balance['available_margin']['value']}"
      puts "  Total margin: $#{balance['initial_margin']['value']}"
      puts "  Liquidation buffer: #{balance['liquidation_buffer_percentage']}%"
      puts "  Unrealized PnL: $#{balance['unrealized_pnl']['value']}"
    rescue => e
      puts "Margin information unavailable: #{e.message}"
    end

    puts "=== End Report ==="
  end

  desc "Send position monitoring alerts via Slack"
  task send_alerts: :environment do
    puts "Checking for position monitoring alerts..."

    # Check day trading positions needing closure
    day_positions_needing_closure = Position.open.day_trading.where("entry_time < ?", 24.hours.ago)
    if day_positions_needing_closure.any?
      SlackNotificationService.position_type_alert(
        "day_trading",
        "closure",
        "#{day_positions_needing_closure.count} day trading positions need immediate closure",
        "Positions have been open for over 24 hours and violate day trading rules"
      )
      puts "Sent day trading closure alert for #{day_positions_needing_closure.count} positions"
    end

    # Check swing positions exceeding max hold
    swing_positions_exceeding = Position.open.swing_trading.where("entry_time < ?", 14.days.ago)
    if swing_positions_exceeding.any?
      SlackNotificationService.position_type_alert(
        "swing_trading",
        "warning",
        "#{swing_positions_exceeding.count} swing positions exceed maximum hold period",
        "Positions have been open for over 14 days"
      )
      puts "Sent swing trading warning alert for #{swing_positions_exceeding.count} positions"
    end

    # Check exposure limits
    day_exposure = calculate_exposure(Position.open.day_trading)
    swing_exposure = calculate_exposure(Position.open.swing_trading)
    
    config = Rails.application.config.monitoring_config
    max_day_exposure = config[:max_day_trading_exposure] * 100
    max_swing_exposure = config[:max_swing_trading_exposure] * 100

    exposure_warnings = []
    exposure_warnings << "Day trading: #{day_exposure.round(2)}%" if day_exposure > max_day_exposure
    exposure_warnings << "Swing trading: #{swing_exposure.round(2)}%" if swing_exposure > max_swing_exposure

    if exposure_warnings.any?
      SlackNotificationService.portfolio_exposure_alert({
        day_trading_exposure: day_exposure.round(2),
        swing_trading_exposure: swing_exposure.round(2),
        total_exposure: (day_exposure + swing_exposure).round(2),
        warnings: exposure_warnings
      })
      puts "Sent portfolio exposure alert"
    end

    puts "Position monitoring alerts check completed"
  end

  private

  def calculate_exposure(positions)
    return 0.0 if positions.empty?
    
    total_notional = positions.sum { |pos| pos.size * pos.entry_price }
    # This should be replaced with actual account balance from Coinbase
    total_portfolio_value = 100_000.0
    
    (total_notional / total_portfolio_value * 100).to_f
  end
end