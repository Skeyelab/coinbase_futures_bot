#!/usr/bin/env ruby

# Simple script to test the sentiment endpoint directly
require "rails"
require "active_record"
require "action_controller"
require "action_dispatch"

# Set up Rails environment
ENV["RAILS_ENV"] = "test"
require "./config/application"
Rails.application.initialize!

# Test the controller directly
controller = SentimentController.new
controller.request = ActionDispatch::TestRequest.create
controller.response = ActionDispatch::TestResponse.new

# Create test data
SentimentAggregate.create!(
  symbol: "BTC-USD",
  window: "15m",
  window_end_at: Time.now.utc.change(sec: 0),
  count: 2,
  avg_score: 0.1,
  weighted_score: 0.15,
  z_score: 1.2
)

# Call the action
controller.aggregates

# Check the response
body = JSON.parse(controller.response.body)
puts "Response keys: #{body.keys}"
puts "Data present: #{body.key?("data")}"
puts "Data is array: #{body["data"].is_a?(Array)}"
puts "First data item z_score: #{body["data"].first["z_score"]}"
