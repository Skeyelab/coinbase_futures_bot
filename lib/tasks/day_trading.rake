# frozen_string_literal: true

namespace :day_trading do
  desc 'Check day trading positions that need closure'
  task check_positions: :environment do
    manager = Trading::DayTradingPositionManager.new
    summary = manager.get_position_summary

    puts 'Day Trading Position Summary:'
    puts "  Open positions: #{summary[:open_count]}"
    puts "  Closed today: #{summary[:closed_today_count]}"
    puts "  Total open value: #{summary[:total_open_value]}"
    puts "  Total PnL: #{summary[:total_pnl]}"
    puts "  Positions needing closure: #{summary[:positions_needing_closure]}"
    puts "  Positions approaching closure: #{summary[:positions_approaching_closure]}"

    if summary[:positions_needing_closure] > 0
      puts "\n⚠️  WARNING: #{summary[:positions_needing_closure]} positions need immediate closure!"
    end

    if summary[:positions_approaching_closure] > 0
      puts "\n⚠️  WARNING: #{summary[:positions_approaching_closure]} positions are approaching closure time!"
    end
  end

  desc 'Close expired day trading positions'
  task close_expired: :environment do
    manager = Trading::DayTradingPositionManager.new

    if manager.positions_need_closure?
      puts 'Closing expired day trading positions...'
      closed_count = manager.close_expired_positions
      puts "✅ Closed #{closed_count} expired positions"
    else
      puts '✅ No expired positions to close'
    end
  end

  desc 'Close positions approaching closure time'
  task close_approaching: :environment do
    manager = Trading::DayTradingPositionManager.new

    if manager.positions_approaching_closure?
      puts 'Closing positions approaching closure time...'
      closed_count = manager.close_approaching_positions
      puts "✅ Closed #{closed_count} approaching positions"
    else
      puts '✅ No approaching positions to close'
    end
  end

  desc 'Force close all day trading positions'
  task force_close_all: :environment do
    manager = Trading::DayTradingPositionManager.new
    summary = manager.get_position_summary
    force = ENV['FORCE'] == 'true'

    if summary[:open_count] == 0
      puts '✅ No open day trading positions to close'
      next
    end

    puts "⚠️  Force closing all #{summary[:open_count]} day trading positions..."
    puts 'This action cannot be undone!'

    if force
      puts 'Force mode enabled - proceeding without confirmation'
      closed_count = manager.force_close_all_day_trading_positions
      puts "✅ Force closed #{closed_count} day trading positions"
    else
      print "Are you sure? Type 'yes' to confirm (or set FORCE=true to skip): "

      # Handle non-interactive scenarios gracefully
      if $stdin.tty?
        confirmation = $stdin.gets&.chomp
        if confirmation&.casecmp('yes')&.zero?
          closed_count = manager.force_close_all_day_trading_positions
          puts "✅ Force closed #{closed_count} day trading positions"
        else
          puts '❌ Operation cancelled'
        end
      else
        puts "\n⚠️  Non-interactive environment detected. Set FORCE=true to run without confirmation."
        puts 'Example: FORCE=true bundle exec rake day_trading:force_close_all'
        exit 1
      end
    end
  end

  desc 'Check take profit and stop loss triggers'
  task check_tp_sl: :environment do
    manager = Trading::DayTradingPositionManager.new
    triggered_positions = manager.check_tp_sl_triggers
    force = ENV['FORCE'] == 'true'

    if triggered_positions.empty?
      puts '✅ No TP/SL triggers found'
      next
    end

    puts "Found #{triggered_positions.size} positions with triggered TP/SL:"
    triggered_positions.each do |trigger_info|
      position = trigger_info[:position]
      trigger = trigger_info[:trigger]
      current_price = trigger_info[:current_price]
      target_price = trigger_info[:target_price]

      puts "  Position #{position.id}: #{position.side} #{position.size} #{position.product_id}"
      puts "    #{trigger.upcase} triggered at #{current_price} (target: #{target_price})"
    end

    if force
      puts 'Force mode enabled - proceeding to close positions without confirmation'
      closed_count = manager.close_tp_sl_positions
      puts "✅ Closed #{closed_count} TP/SL positions"
    else
      print "Close these positions now? Type 'yes' to confirm (or set FORCE=true to skip): "

      # Handle non-interactive scenarios gracefully
      if $stdin.tty?
        confirmation = $stdin.gets&.chomp
        if confirmation&.casecmp('yes')&.zero?
          closed_count = manager.close_tp_sl_positions
          puts "✅ Closed #{closed_count} TP/SL positions"
        else
          puts '❌ Operation cancelled'
        end
      else
        puts "\n⚠️  Non-interactive environment detected. Set FORCE=true to run without confirmation."
        puts 'Example: FORCE=true bundle exec rake day_trading:check_tp_sl'
        exit 1
      end
    end
  end

  desc 'Get current PnL for all open positions'
  task pnl: :environment do
    manager = Trading::DayTradingPositionManager.new
    total_pnl = manager.calculate_total_pnl

    puts "Current PnL for open day trading positions: #{total_pnl}"

    # Show individual position PnL
    positions = Position.open_day_trading_positions
    if positions.any?
      puts "\nIndividual position PnL:"
      current_prices = manager.get_current_prices

      positions.each do |position|
        current_price = current_prices[position.id]
        if current_price
          pnl = position.calculate_pnl(current_price)
          puts "  #{position.product_id}: #{position.side} #{position.size} - PnL: #{pnl}"
        else
          puts "  #{position.product_id}: #{position.side} #{position.size} - PnL: unknown (no price data)"
        end
      end
    end
  end

  desc 'Clean up old closed positions (default: 30 days)'
  task cleanup: :environment do
    days_old = ENV['DAYS_OLD']&.to_i || 30
    force = ENV['FORCE'] == 'true'

    puts "Cleaning up closed positions older than #{days_old} days..."

    old_count = Position.closed.where('close_time < ?', days_old.days.ago).count
    if old_count == 0
      puts '✅ No old positions to clean up'
      next
    end

    if force
      puts 'Force mode enabled - proceeding without confirmation'
      deleted_count = Position.cleanup_old_positions(days_old)
      puts "✅ Cleaned up #{deleted_count} old positions"
    else
      print "Delete #{old_count} old positions? Type 'yes' to confirm (or set FORCE=true to skip): "

      # Handle non-interactive scenarios gracefully
      if $stdin.tty?
        confirmation = $stdin.gets&.chomp
        if confirmation&.casecmp('yes')&.zero?
          deleted_count = Position.cleanup_old_positions(days_old)
          puts "✅ Cleaned up #{deleted_count} old positions"
        else
          puts '❌ Operation cancelled'
        end
      else
        puts "\n⚠️  Non-interactive environment detected. Set FORCE=true to run without confirmation."
        puts 'Example: FORCE=true bundle exec rake day_trading:cleanup'
        exit 1
      end
    end
  end

  desc 'Show detailed position information'
  task details: :environment do
    positions = Position.open_day_trading_positions.includes(:trading_pair)

    if positions.empty?
      puts '✅ No open day trading positions'
      next
    end

    puts 'Open Day Trading Positions:'
    puts '=' * 80

    positions.each do |position|
      puts "Position ID: #{position.id}"
      puts "  Product: #{position.product_id}"
      puts "  Side: #{position.side}"
      puts "  Size: #{position.size}"
      puts "  Entry Price: #{position.entry_price}"
      puts "  Entry Time: #{position.entry_time}"
      puts "  Duration: #{position.duration_hours&.round(2)} hours"
      puts "  Take Profit: #{position.take_profit}"
      puts "  Stop Loss: #{position.stop_loss}"

      if position.trading_pair
        puts "  Contract Type: #{position.trading_pair.contract_type}"
        puts "  Expiration: #{position.trading_pair.expiration_date}"
      end

      puts '-' * 40
    end
  end

  desc 'Run full day trading position management'
  task manage: :environment do
    puts 'Running full day trading position management...'

    # Check positions
    Rake::Task['day_trading:check_positions'].invoke

    # Close expired positions
    Rake::Task['day_trading:close_expired'].invoke

    # Close approaching positions
    Rake::Task['day_trading:close_approaching'].invoke

    # Check TP/SL triggers
    Rake::Task['day_trading:check_tp_sl'].invoke

    puts "\n✅ Day trading position management completed"
  end
end
