# frozen_string_literal: true

namespace :trading do
  desc "Halt all trading immediately. Optional REASON='...' env var."
  task halt: :environment do
    reason = ENV["REASON"].presence
    status = TradingHalt.halt!(reason: reason)
    puts "🔴 Trading HALTED"
    puts "   Reason : #{status[:reason] || "(none)"}"
    puts "   As of  : #{status[:as_of]}"
  end

  desc "Resume trading after a halt"
  task resume: :environment do
    status = TradingHalt.resume!
    puts "🟢 Trading RESUMED"
    puts "   As of : #{status[:as_of]}"
  end

  desc "Show current trading halt status"
  task status: :environment do
    status = TradingHalt.status
    if status[:active]
      puts "🟢 Trading is ACTIVE"
    else
      puts "🔴 Trading is HALTED"
      puts "   Reason : #{status[:reason] || "(none)"}"
    end
    puts "   As of  : #{status[:as_of]}"
  end
end
