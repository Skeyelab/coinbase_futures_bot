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
    match_requests_on: [ :method, :uri, :body ]
  }
end
