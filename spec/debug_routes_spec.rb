# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Debug Routes", type: :request do
  let(:api_key) { "test_api_key_123" }

  before do
    @original_api_key = ENV["SIGNALS_API_KEY"]
    ENV["SIGNALS_API_KEY"] = api_key
  end

  after do
    ENV["SIGNALS_API_KEY"] = @original_api_key
  end

  it "checks if signals routes are available" do
    puts "Rails version: #{Rails.version}"
    puts "Rails env: #{Rails.env}"
    puts "Routes loaded: #{Rails.application.routes.routes.size}"
    puts "API Key set: #{ENV["SIGNALS_API_KEY"]}"

    signals_routes = Rails.application.routes.routes.select do |route|
      route.path.spec.to_s.include?("signals")
    end

    puts "Signals routes found: #{signals_routes.size}"
    signals_routes.each do |route|
      puts "  #{route.path.spec} -> #{route.defaults[:controller]}##{route.defaults[:action]}"
    end

    # Try to make a request with proper API key
    get "/signals", headers: {"X-API-Key" => api_key}
    puts "Response status: #{response.status}"
    puts "Response body: #{response.body[0..200]}"

    # Try health endpoint (no auth required)
    get "/signals/health"
    puts "Health status: #{response.status}"
    puts "Health body: #{response.body[0..200]}"
  end
end
