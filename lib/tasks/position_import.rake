# frozen_string_literal: true

namespace :positions do
  desc "Import positions from Coinbase"
  task import: :environment do
    puts "\u{1F504} Importing positions from Coinbase..."

    begin
      service = PositionImportService.new
      result = service.import_positions_from_coinbase

      puts "\u2705 Import complete!"
      puts "   📥 Imported: #{result[:imported]} new positions"
      puts "   🔄 Updated: #{result[:updated]} existing positions"
      puts "   📊 Total on Coinbase: #{result[:total_coinbase]}"

      if result[:errors].any?
        puts "   \u26A0\uFE0F  Errors:"
        result[:errors].each { |error| puts "      - #{error}" }
      end
    rescue => e
      puts "❌ Import failed: #{e.message}"
      exit 1
    end
  end

  desc "Clear all positions and import from Coinbase (full replacement)"
  task replace: :environment do
    puts "\u{1F504} Replacing all positions with Coinbase data..."

    begin
      service = PositionImportService.new
      result = service.import_and_replace

      puts "\u2705 Replacement complete!"
      puts "   🗑️  Cleared: #{result[:cleared]} positions"
      puts "   📥 Imported: #{result[:imported]} new positions"
      puts "   📊 Total on Coinbase: #{result[:total_coinbase]}"

      if result[:errors].any?
        puts "   \u26A0\uFE0F  Errors:"
        result[:errors].each { |error| puts "      - #{error}" }
      end
    rescue => e
      puts "❌ Replacement failed: #{e.message}"
      exit 1
    end
  end

  desc "List current positions in database"
  task list: :environment do
    puts "\u{1F4CA} Current positions in database:"
    puts "   Total: #{Position.count}"
    puts "   Open: #{Position.open.count}"
    puts "   Closed: #{Position.closed.count}"

    if Position.open.any?
      puts "\n📋 Open positions:"
      Position.open.each do |pos|
        puts "   • #{pos.side} #{pos.size} #{pos.product_id} @ $#{pos.entry_price} (PnL: $#{pos.pnl || "N/A"})"
      end
    end
  end

  desc "Test Coinbase connection"
  task test_connection: :environment do
    puts "\u{1F50C} Testing Coinbase connection..."

    begin
      client = Coinbase::Client.new
      auth_result = client.test_auth

      if auth_result[:advanced_trade][:ok]
        puts "\u2705 Advanced Trade API: Connected"

        # Try to fetch positions
        positions = client.futures_positions
        puts "   📊 Found #{positions.size} positions on Coinbase"

        if positions.any?
          puts "   \u{1F4CB} Sample positions:"
          positions.first(3).each do |pos|
            puts "      • #{pos["side"]} #{pos["size"]} #{pos["product_id"]} @ $#{pos["entry_price"]}"
          end
        end
      else
        puts "\u274C Advanced Trade API: Failed"
        puts "   Error: #{auth_result[:advanced_trade][:message]}"
      end
    rescue => e
      puts "❌ Connection test failed: #{e.message}"
      exit 1
    end
  end

  desc "Deep diagnostic: inspect Coinbase position-bearing endpoints"
  task diagnose_endpoints: :environment do
    puts "🔎 Diagnosing Coinbase position endpoints..."

    client = Coinbase::Client.new
    advanced = client.advanced_trade

    auth_status = client.auth_status
    puts "   Auth status: advanced_trade=#{auth_status[:advanced_trade]} exchange=#{auth_status[:exchange]}"

    permissions = begin
      advanced.get_api_key_permissions
    rescue => e
      {"error" => "#{e.class}: #{e.message}"}
    end
    puts "   Key permissions: #{permissions}"

    futures_positions = begin
      advanced.list_futures_positions
    rescue => e
      puts "❌ futures positions call failed: #{e.class}: #{e.message}"
      []
    end
    puts "   Futures positions count: #{futures_positions.size}"
    if futures_positions.any?
      puts "   Futures positions sample:"
      futures_positions.first(3).each do |pos|
        puts "      • #{pos.slice("product_id", "side", "number_of_contracts", "avg_entry_price", "portfolio_uuid")}"
      end
    end

    accounts = begin
      advanced.get_accounts
    rescue => e
      puts "❌ accounts call failed: #{e.class}: #{e.message}"
      {}
    end
    account_list = accounts.is_a?(Hash) ? accounts["accounts"] || [] : Array(accounts)
    puts "   Accounts count: #{account_list.size}"

    non_zero_accounts = account_list.select do |acct|
      raw = acct.dig("available_balance", "value") || acct.dig("balance", "value")
      raw.to_f > 0
    end
    puts "   Accounts with non-zero balance: #{non_zero_accounts.size}"
    non_zero_accounts.first(5).each do |acct|
      puts "      • #{acct.slice("name", "uuid", "type", "currency")}"
    end

    balance_summary = begin
      advanced.get_futures_balance_summary
    rescue => e
      {"error" => "#{e.class}: #{e.message}"}
    end
    puts "   Futures balance summary keys: #{balance_summary.is_a?(Hash) ? balance_summary.keys : balance_summary.class}"
    puts "   Futures balance summary sample: #{balance_summary}"
  end
end
