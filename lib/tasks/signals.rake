# frozen_string_literal: true

namespace :signals do
  desc "Run multi-timeframe signal generation for enabled pairs"
  task run: :environment do
    equity = (ENV["SIGNAL_EQUITY_USD"] || 10_000).to_f
    if ENV["INLINE"].to_s == "1"
      GenerateSignalsJob.new.perform(equity_usd: equity)
    else
      GenerateSignalsJob.perform_later(equity_usd: equity)
      puts "Enqueued GenerateSignalsJob (equity_usd=#{equity})"
    end
  end
end
