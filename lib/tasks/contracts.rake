# frozen_string_literal: true

namespace :contracts do
  desc "Check positions approaching contract expiry"
  task check_expiry: :environment do
    puts "=== Contract Expiry Check ==="

    buffer_days = ENV.fetch("BUFFER_DAYS", "2").to_i
    expiry_manager = ContractExpiryManager.new

    # Generate comprehensive report
    report = expiry_manager.generate_expiry_report

    puts "Total open positions: #{report[:total_positions]}"
    puts "Positions with known expiry: #{report[:positions_with_known_expiry]}"
    puts "Expiring today: #{report[:expiring_today]}"
    puts "Expiring tomorrow: #{report[:expiring_tomorrow]}"
    puts "Expiring within week: #{report[:expiring_within_week]}"
    puts "Already expired: #{report[:expired]}"

    if report[:by_days].any?
      puts "\nBreakdown by days until expiry:"
      report[:by_days].each do |days, count|
        days_str = days.nil? ? "unknown" : days.to_s
        puts "  #{days_str} days: #{count} positions"
      end
    end

    # Show detailed information for positions expiring soon
    expiring_positions = expiry_manager.positions_approaching_expiry(buffer_days)

    if expiring_positions.any?
      puts "\n=== Positions Expiring Within #{buffer_days} Days ==="
      expiring_positions.each do |position|
        days = position.days_until_expiry
        expiry_date = position.expiry_date
        margin_impact = position.margin_impact_near_expiry

        puts "Position #{position.id}:"
        puts "  Product: #{position.product_id}"
        puts "  Side: #{position.side}"
        puts "  Size: #{position.size} contracts"
        puts "  Entry Price: $#{position.entry_price}"
        puts "  Entry Time: #{position.entry_time}"
        puts "  Days Until Expiry: #{days}"
        puts "  Expiry Date: #{expiry_date}"
        puts "  Margin Impact: #{margin_impact[:reason]}"
        puts "  Day Trading: #{position.day_trading?}"
        puts ""
      end
    else
      puts "\nNo positions expiring within #{buffer_days} days."
    end

    # Check for expired positions
    expired_positions = Position.expired_positions
    if expired_positions.any?
      puts "\n=== EXPIRED POSITIONS (URGENT) ==="
      expired_positions.each do |position|
        days = position.days_until_expiry
        puts "EXPIRED Position #{position.id}: #{position.product_id} (#{position.side} #{position.size}) expired #{days.abs} days ago"
      end
    end

    puts "\n=== End Check ==="
  end

  desc "Close positions approaching contract expiry"
  task close_expiring: :environment do
    puts "=== Closing Expiring Positions ==="

    buffer_days = ENV.fetch("BUFFER_DAYS", "2").to_i
    dry_run = ENV.fetch("DRY_RUN", "false").downcase == "true"

    expiry_manager = ContractExpiryManager.new
    expiring_positions = expiry_manager.positions_approaching_expiry(buffer_days)

    if expiring_positions.empty?
      puts "No positions expiring within #{buffer_days} days."
      exit 0
    end

    puts "Found #{expiring_positions.size} positions expiring within #{buffer_days} days:"
    expiring_positions.each do |position|
      days = position.days_until_expiry
      puts "  - #{position.product_id}: #{position.side} #{position.size} contracts (expires in #{days} days)"
    end

    if dry_run
      puts "\nDRY RUN MODE - No positions will be closed"
      puts "To actually close positions, run: BUFFER_DAYS=#{buffer_days} bundle exec rake contracts:close_expiring"
    else
      puts "\nClosing positions..."
      closed_count = expiry_manager.close_expiring_positions(buffer_days)
      puts "Successfully closed #{closed_count} positions"

      if closed_count < expiring_positions.size
        failed_count = expiring_positions.size - closed_count
        puts "WARNING: #{failed_count} positions could not be closed. Check logs for details."
      end
    end
  end

  desc "Emergency closure of expired positions"
  task close_expired: :environment do
    puts "=== Emergency Closure of Expired Positions ==="

    dry_run = ENV.fetch("DRY_RUN", "false").downcase == "true"

    expiry_manager = ContractExpiryManager.new
    expired_positions = Position.expired_positions

    if expired_positions.empty?
      puts "No expired positions found."
      exit 0
    end

    puts "CRITICAL: Found #{expired_positions.size} expired positions:"
    expired_positions.each do |position|
      days = position.days_until_expiry
      puts "  - #{position.product_id}: #{position.side} #{position.size} contracts (expired #{days.abs} days ago)"
    end

    if dry_run
      puts "\nDRY RUN MODE - No positions will be closed"
      puts "To actually close expired positions, run: bundle exec rake contracts:close_expired"
    else
      puts "\nEMERGENCY: Closing expired positions..."
      closed_count = expiry_manager.close_expired_positions
      puts "Successfully closed #{closed_count} expired positions"

      if closed_count < expired_positions.size
        failed_count = expired_positions.size - closed_count
        puts "CRITICAL: #{failed_count} expired positions could not be closed. Manual intervention required!"
      end
    end
  end

  desc "List all contract expiry dates"
  task list_expiry_dates: :environment do
    puts "=== Contract Expiry Dates ==="

    positions = Position.open.to_a

    if positions.empty?
      puts "No open positions found."
      exit 0
    end

    # Group by product_id and show expiry information
    positions_by_product = positions.group_by(&:product_id)

    puts "Product ID".ljust(20) + "Expiry Date".ljust(15) + "Days Until".ljust(12) + "Positions"
    puts "-" * 60

    positions_by_product.sort_by { |product_id, _| FuturesContract.days_until_expiry(product_id) || Float::INFINITY }.each do |product_id, pos_list|
      expiry_date = FuturesContract.parse_expiry_date(product_id)
      days_until = FuturesContract.days_until_expiry(product_id)

      expiry_str = expiry_date ? expiry_date.strftime("%Y-%m-%d") : "Unknown"
      days_str = days_until ? days_until.to_s : "Unknown"

      # Color code based on urgency
      urgency_marker = case days_until
      when nil then "?"
      when (..0) then "🔴"  # Expired
      when (1..1) then "🟠"  # Expiring today/tomorrow
      when (2..7) then "🟡"  # Expiring this week
      else "🟢"  # Safe
      end

      puts "#{urgency_marker} #{product_id.ljust(18)} #{expiry_str.ljust(15)} #{days_str.ljust(12)} #{pos_list.size} positions"

      # Show position details for expiring contracts
      if days_until && days_until <= 7
        pos_list.each do |position|
          puts "    └─ Position #{position.id}: #{position.side} #{position.size} contracts"
        end
      end
    end

    puts "\nLegend:"
    puts "🔴 Expired (immediate action required)"
    puts "🟠 Expiring today/tomorrow (urgent)"
    puts "🟡 Expiring this week (attention needed)"
    puts "🟢 Safe (more than 1 week)"
    puts "? Unknown expiry date"
  end

  desc "Validate contract expiry dates"
  task validate_expiry_dates: :environment do
    puts "=== Validating Contract Expiry Dates ==="

    expiry_manager = ContractExpiryManager.new
    validation_results = expiry_manager.validate_expiry_dates

    valid_results = validation_results.select { |r| r[:valid] }
    invalid_results = validation_results.reject { |r| r[:valid] }

    puts "Total positions validated: #{validation_results.size}"
    puts "Valid expiry dates: #{valid_results.size}"
    puts "Invalid expiry dates: #{invalid_results.size}"

    if invalid_results.any?
      puts "\n=== Invalid Expiry Dates ==="
      invalid_results.each do |result|
        puts "Position #{result[:position_id]}: #{result[:product_id]} - Could not parse expiry date"
      end

      puts "\nThese positions may need manual review or contract rollover."
    end

    # Show API vs parsed comparison for valid results
    api_mismatches = valid_results.select do |r|
      r[:api_days_until_expiry] && r[:days_until_expiry] &&
        (r[:api_days_until_expiry] - r[:days_until_expiry]).abs > 1
    end

    if api_mismatches.any?
      puts "\n=== API vs Parsed Date Mismatches ==="
      api_mismatches.each do |result|
        puts "Position #{result[:position_id]}: #{result[:product_id]}"
        puts "  Parsed: #{result[:days_until_expiry]} days"
        puts "  API: #{result[:api_days_until_expiry]} days"
      end
    end
  end

  desc "Monitor margin requirements near expiry"
  task check_margin_requirements: :environment do
    puts "=== Margin Requirements Near Expiry ==="

    buffer_days = ENV.fetch("BUFFER_DAYS", "5").to_i
    expiry_manager = ContractExpiryManager.new

    margin_warnings = expiry_manager.check_margin_requirements_near_expiry(buffer_days)

    if margin_warnings.empty?
      puts "No margin requirement increases found for positions expiring within #{buffer_days} days."
    else
      puts "Found #{margin_warnings.size} positions with increased margin requirements:"

      margin_warnings.each do |warning|
        position = warning[:position]
        impact = warning[:margin_impact]
        days = position.days_until_expiry

        puts "\nPosition #{position.id}: #{position.product_id}"
        puts "  Size: #{position.side} #{position.size} contracts"
        puts "  Days until expiry: #{days}"
        puts "  Margin impact: #{impact[:reason]}"
        puts "  Margin multiplier: #{impact[:multiplier]}x"
      end
    end
  end

  desc "Generate comprehensive expiry report"
  task report: :environment do
    puts "=== Comprehensive Contract Expiry Report ==="
    puts "Generated at: #{Time.current.strftime("%Y-%m-%d %H:%M:%S UTC")}"
    puts ""

    expiry_manager = ContractExpiryManager.new

    # Basic report
    report = expiry_manager.generate_expiry_report

    puts "=== Summary ==="
    puts "Total open positions: #{report[:total_positions]}"
    puts "Positions with known expiry: #{report[:positions_with_known_expiry]}"
    puts "Positions expiring today: #{report[:expiring_today]}"
    puts "Positions expiring tomorrow: #{report[:expiring_tomorrow]}"
    puts "Positions expiring within week: #{report[:expiring_within_week]}"
    puts "Already expired positions: #{report[:expired]}"
    puts ""

    # Detailed breakdown
    if report[:by_days].any?
      puts "=== Expiry Timeline ==="
      report[:by_days].each do |days, count|
        days_str = case days
        when nil then "Unknown expiry"
        when 0 then "Expiring TODAY"
        when 1 then "Expiring TOMORROW"
        when (2..7) then "Expiring in #{days} days"
        when (8..30) then "Expiring in #{days} days"
        else "Expiring in #{days} days"
        end

        urgency = case days
        when nil then "⚠️ "
        when (..0) then "🔴 "
        when (1..1) then "🟠 "
        when (2..7) then "🟡 "
        else "🟢 "
        end

        puts "#{urgency}#{days_str}: #{count} positions"
      end
      puts ""
    end

    # Margin impact analysis
    puts "=== Margin Impact Analysis ==="
    margin_warnings = expiry_manager.check_margin_requirements_near_expiry(7)

    if margin_warnings.any?
      puts "Positions with increased margin requirements:"
      margin_warnings.group_by { |w| w[:margin_impact][:multiplier] }.each do |multiplier, warnings|
        puts "  #{multiplier}x margin (#{warnings.size} positions): #{warnings.map { |w| w[:position].product_id }.uniq.join(", ")}"
      end
    else
      puts "No positions with increased margin requirements."
    end
    puts ""

    # Validation summary
    puts "=== Data Validation ==="
    validation_results = expiry_manager.validate_expiry_dates
    invalid_count = validation_results.count { |r| !r[:valid] }

    if invalid_count > 0
      puts "⚠️  #{invalid_count} positions have invalid/unparseable expiry dates"
    else
      puts "✅ All positions have valid expiry date parsing"
    end

    puts ""
    puts "=== End Report ==="
  end
end
