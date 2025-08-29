#!/usr/bin/env ruby

require "./config/application"
Rails.application.initialize!

# Load the strategy class
require "./app/services/strategy/multi_timeframe_signal"

# Test the EMA method directly
strategy = Strategy::MultiTimeframeSignal.new
values = [100, 102, 104, 103, 105]
period = 3

puts "Testing EMA calculation:"
puts "Values: #{values.inspect}"
puts "Period: #{period}"

result = strategy.send(:ema, values, period)
puts "Result: #{result}"

# Expected calculation
k = 2.0 / (period + 1) # 0.5
expected = 100.0 # Start with first value
values.each do |v|
  expected = v * k + expected * (1 - k)
end

puts "Expected: #{expected}"
puts "Match: #{result == expected}"
