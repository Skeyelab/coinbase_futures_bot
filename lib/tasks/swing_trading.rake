# frozen_string_literal: true

namespace :swing_trading do
  desc "Check swing trading positions status"
  task check_positions: :environment do
    manager = Trading::SwingPositionManager.new
    summary = manager.get_swing_position_summary

    puts "\n🔄 Swing Trading Positions Summary"
    puts "=" * 50
    puts "Total positions: #{summary[:total_positions]}"
    puts "Total exposure: $#{summary[:total_exposure].round(2)}"
    puts "Unrealized PnL: $#{summary[:unrealized_pnl].round(2)}"

    if summary[:positions_by_asset].any?
      puts "\nBy Asset:"
      summary[:positions_by_asset].each do |asset, data|
        puts "  #{asset}: #{data[:count]} positions, $#{data[:exposure].round(2)} exposure, $#{data[:pnl].round(2)} PnL"
      end
    end

    if summary[:risk_metrics].any?
      puts "\nRisk Metrics:"
      metrics = summary[:risk_metrics]
      puts "  Average position size: $#{metrics[:avg_position_size]&.round(2)}"
      puts "  Largest position: $#{metrics[:largest_position]&.round(2)}"
      puts "  Average hold time: #{metrics[:avg_hold_time_hours]&.round(1)} hours"
      puts "  Positions approaching expiry: #{metrics[:positions_approaching_expiry]}"
      puts "  Positions exceeding max hold: #{metrics[:positions_exceeding_max_hold]}"
      puts "  TP/SL triggered positions: #{metrics[:tp_sl_triggered_positions]}"

      if metrics[:max_asset_concentration]
        puts "  Max asset concentration: #{(metrics[:max_asset_concentration] * 100).round(1)}%"
      end
    end

    puts "\nPosition Details:"
    if summary[:positions].any?
      summary[:positions].each do |pos|
        pnl_color = (pos[:unrealized_pnl] >= 0) ? "+" : ""
        puts "  #{pos[:product_id]} | #{pos[:side]} #{pos[:size]} | Entry: $#{pos[:entry_price]} | " \
             "Current: $#{pos[:current_price] || "N/A"} | PnL: #{pnl_color}$#{pos[:unrealized_pnl].round(2)} | " \
             "Age: #{pos[:duration_hours]&.round(1)}h"
      end
    else
      puts "  No open swing positions"
    end
    puts
  end

  desc "Check swing trading balance and margin"
  task check_balance: :environment do
    manager = Trading::SwingPositionManager.new
    balance = manager.get_swing_balance_summary

    puts "\n💰 Swing Trading Balance Summary"
    puts "=" * 50

    if balance[:error]
      puts "❌ Error: #{balance[:error]}"
      exit 1
    end

    puts "Total USD Balance: $#{balance[:total_usd_balance].round(2)}"
    puts "CFM USD Balance: $#{balance[:cfm_usd_balance].round(2)}"
    puts "Futures Buying Power: $#{balance[:futures_buying_power].round(2)}"
    puts "Available Margin: $#{balance[:available_margin].round(2)}"
    puts "Initial Margin: $#{balance[:initial_margin].round(2)}"
    puts "Unrealized PnL: $#{balance[:unrealized_pnl].round(2)}"
    puts "Liquidation Threshold: $#{balance[:liquidation_threshold].round(2)}"
    puts "Liquidation Buffer: $#{balance[:liquidation_buffer_amount].round(2)} (#{(balance[:liquidation_buffer_percentage] * 100).round(1)}%)"
    puts "Overnight Margin Enabled: #{balance[:overnight_margin_enabled] ? "✅" : "❌"}"

    if balance[:margin_window].any?
      puts "\nMargin Window:"
      puts "  Type: #{balance[:margin_window]["margin_window_type"]}"
      puts "  End Time: #{balance[:margin_window]["end_time"]}" if balance[:margin_window]["end_time"]
    end
    puts
  end

  desc "Check swing trading risk limits"
  task check_risk: :environment do
    manager = Trading::SwingPositionManager.new
    risk_check = manager.check_swing_risk_limits

    puts "\n⚠️  Swing Trading Risk Assessment"
    puts "=" * 50

    if risk_check[:error]
      puts "❌ Error: #{risk_check[:error]}"
      exit 1
    end

    puts "Risk Status: #{risk_check[:risk_status].upcase}"
    puts "Total Exposure: $#{risk_check[:total_exposure].round(2)}"
    puts "Available Margin: $#{risk_check[:available_margin].round(2)}"
    puts "Current Leverage: #{risk_check[:leverage]}x"

    if risk_check[:violations].any?
      puts "\n🚨 Risk Violations:"
      risk_check[:violations].each do |violation|
        puts "  • #{violation[:type].humanize}: #{violation[:message]}"
        puts "    Current: #{violation[:current]} | Limit: #{violation[:limit] || violation[:required]}"
      end
    else
      puts "\n✅ All risk limits within acceptable ranges"
    end
    puts
  end

  desc "Close swing positions approaching contract expiry"
  task close_expiring: :environment do
    manager = Trading::SwingPositionManager.new

    positions = manager.positions_approaching_expiry
    puts "\n📅 Positions Approaching Contract Expiry"
    puts "=" * 50
    puts "Found #{positions.size} positions approaching expiry"

    if positions.any?
      puts "\nClosing expiring positions..."
      closed_count = manager.close_expiring_positions
      puts "✅ Successfully closed #{closed_count} positions"
    else
      puts "No positions need closure due to expiry"
    end
    puts
  end

  desc "Close swing positions exceeding maximum hold period"
  task close_max_hold: :environment do
    manager = Trading::SwingPositionManager.new

    positions = manager.positions_exceeding_max_hold
    puts "\n⏰ Positions Exceeding Maximum Hold Period"
    puts "=" * 50
    puts "Found #{positions.size} positions exceeding max hold"

    if positions.any?
      puts "\nClosing positions exceeding max hold..."
      closed_count = manager.close_max_hold_positions
      puts "✅ Successfully closed #{closed_count} positions"
    else
      puts "No positions exceed maximum hold period"
    end
    puts
  end

  desc "Check and close swing positions that hit TP/SL"
  task check_tp_sl: :environment do
    manager = Trading::SwingPositionManager.new

    triggered = manager.check_swing_tp_sl_triggers
    puts "\n🎯 Take Profit / Stop Loss Check"
    puts "=" * 50
    puts "Found #{triggered.size} positions with TP/SL triggers"

    if triggered.any?
      puts "\nTriggered positions:"
      triggered.each do |trigger|
        pos = trigger[:position]
        puts "  #{pos.product_id} | #{pos.side} | #{trigger[:trigger].humanize} at $#{trigger[:current_price]}"
      end

      puts "\nClosing triggered positions..."
      closed_count = manager.close_tp_sl_positions
      puts "✅ Successfully closed #{closed_count} positions"
    else
      puts "No positions have hit TP/SL levels"
    end
    puts
  end

  desc "Force close all swing positions (EMERGENCY USE ONLY)"
  task force_close_all: :environment do
    print "⚠️  WARNING: This will close ALL open swing positions. Are you sure? (y/N): "
    confirmation = $stdin.gets.chomp.downcase

    unless confirmation == "y" || confirmation == "yes"
      puts "Operation cancelled"
      exit 0
    end

    manager = Trading::SwingPositionManager.new
    positions = Position.open_swing_positions

    puts "\n🚨 EMERGENCY: Force Closing All Swing Positions"
    puts "=" * 50
    puts "Found #{positions.count} open swing positions"

    if positions.any?
      closed_count = manager.force_close_all_swing_positions("Manual force closure via rake task")
      puts "✅ Force closed #{closed_count} swing positions"
    else
      puts "No open swing positions to close"
    end
    puts
  end

  desc "Run comprehensive swing position management"
  task manage: :environment do
    puts "\n🔧 Comprehensive Swing Position Management"
    puts "=" * 50

    manager = Trading::SwingPositionManager.new

    # Check positions
    Rake::Task["swing_trading:check_positions"].invoke

    # Check risk
    Rake::Task["swing_trading:check_risk"].invoke

    # Close expiring positions
    expiring_count = manager.close_expiring_positions
    puts "Closed #{expiring_count} positions approaching expiry" if expiring_count > 0

    # Close positions exceeding max hold
    max_hold_count = manager.close_max_hold_positions
    puts "Closed #{max_hold_count} positions exceeding max hold" if max_hold_count > 0

    # Close TP/SL positions
    tp_sl_count = manager.close_tp_sl_positions
    puts "Closed #{tp_sl_count} positions via TP/SL" if tp_sl_count > 0

    total_closed = expiring_count + max_hold_count + tp_sl_count
    puts "\n✅ Management complete. Total positions closed: #{total_closed}"
  end

  desc "Show swing trading configuration"
  task config: :environment do
    config = Rails.application.config.swing_trading_config

    puts "\n⚙️  Swing Trading Configuration"
    puts "=" * 50
    puts "Max Hold Days: #{config[:max_hold_days]}"
    puts "Expiry Buffer Days: #{config[:expiry_buffer_days]}"
    puts "Max Overnight Exposure: #{(config[:max_overnight_exposure] * 100).round(1)}%"
    puts "Enable Contract Roll: #{config[:enable_contract_roll] ? "✅" : "❌"}"
    puts "Margin Safety Buffer: #{(config[:margin_safety_buffer] * 100).round(1)}%"
    puts "Max Leverage Overnight: #{config[:max_leverage_overnight]}x"
    puts
  end
end
