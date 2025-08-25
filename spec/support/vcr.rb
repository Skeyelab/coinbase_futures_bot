# frozen_string_literal: true

require "vcr"

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!

  # Filter out sensitive data
  config.filter_sensitive_data("<COINBASE_API_KEY>") { ENV["COINBASE_API_KEY"] }
  config.filter_sensitive_data("<COINBASE_API_SECRET>") { ENV["COINBASE_API_SECRET"] }

  # Filter out timestamps that change between runs
  config.filter_sensitive_data("<TIMESTAMP>") { Time.now.to_i.to_s }

  # Filter out JWT tokens in Authorization headers (they contain timestamps)
  config.filter_sensitive_data("<JWT_TOKEN>") do |interaction|
    if interaction.request.headers["Authorization"]
      # Extract just the JWT part after "Bearer "
      auth_header = interaction.request.headers["Authorization"].first
      auth_header.sub("Bearer ", "") if auth_header&.start_with?("Bearer ")
    end
  end

  # Filter client order IDs that use UUIDs
  config.before_record do |interaction|
    if interaction.request.body
      body = interaction.request.body
      # Replace UUIDs in client_order_id with a placeholder
      body.gsub!(/("client_order_id":"cli-)[a-f0-9-]+(")/i, '\1<UUID>\2')
    end
  end

  # Ignore Sentry requests
  config.ignore_request do |request|
    request.uri.include?("glitchtip.ger.ericdahl.dev") ||
      request.uri.include?("sentry.io") ||
      request.uri.include?("sentry")
  end

  # Allow real HTTP connections in development if needed
  config.allow_http_connections_when_no_cassette = false

  # Record new cassettes when they don't exist
  config.default_cassette_options = {
    record: :new_episodes,
    match_requests_on: %i[method uri body]
  }
end
