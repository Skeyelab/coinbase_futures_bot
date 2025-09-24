# frozen_string_literal: true

namespace :positions do
  desc 'Import positions from Coinbase'
  task import: :environment do
    puts '🔄 Importing positions from Coinbase...'

    begin
      service = PositionImportService.new
      result = service.import_positions_from_coinbase

      puts '✅ Import complete!'
      puts "   📥 Imported: #{result[:imported]} new positions"
      puts "   🔄 Updated: #{result[:updated]} existing positions"
      puts "   📊 Total on Coinbase: #{result[:total_coinbase]}"

      if result[:errors].any?
        puts '   ⚠️  Errors:'
        result[:errors].each { |error| puts "      - #{error}" }
      end
    rescue StandardError => e
      puts "❌ Import failed: #{e.message}"
      exit 1
    end
  end

  desc 'Clear all positions and import from Coinbase (full replacement)'
  task replace: :environment do
    puts '🔄 Replacing all positions with Coinbase data...'

    begin
      service = PositionImportService.new
      result = service.import_and_replace

      puts '✅ Replacement complete!'
      puts "   🗑️  Cleared: #{result[:cleared]} positions"
      puts "   📥 Imported: #{result[:imported]} new positions"
      puts "   📊 Total on Coinbase: #{result[:total_coinbase]}"

      if result[:errors].any?
        puts '   ⚠️  Errors:'
        result[:errors].each { |error| puts "      - #{error}" }
      end
    rescue StandardError => e
      puts "❌ Replacement failed: #{e.message}"
      exit 1
    end
  end

  desc 'List current positions in database'
  task list: :environment do
    puts '📊 Current positions in database:'
    puts "   Total: #{Position.count}"
    puts "   Open: #{Position.open.count}"
    puts "   Closed: #{Position.closed.count}"

    if Position.open.any?
      puts "\n📋 Open positions:"
      Position.open.each do |pos|
        puts "   • #{pos.side} #{pos.size} #{pos.product_id} @ $#{pos.entry_price} (PnL: $#{pos.pnl || 'N/A'})"
      end
    end
  end

  desc 'Test Coinbase connection'
  task test_connection: :environment do
    puts '🔌 Testing Coinbase connection...'

    begin
      client = Coinbase::Client.new
      auth_result = client.test_auth

      if auth_result[:advanced_trade][:ok]
        puts '✅ Advanced Trade API: Connected'

        # Try to fetch positions
        positions = client.futures_positions
        puts "   📊 Found #{positions.size} positions on Coinbase"

        if positions.any?
          puts '   📋 Sample positions:'
          positions.first(3).each do |pos|
            puts "      • #{pos['side']} #{pos['size']} #{pos['product_id']} @ $#{pos['entry_price']}"
          end
        end
      else
        puts '❌ Advanced Trade API: Failed'
        puts "   Error: #{auth_result[:advanced_trade][:message]}"
      end
    rescue StandardError => e
      puts "❌ Connection test failed: #{e.message}"
      exit 1
    end
  end
end
