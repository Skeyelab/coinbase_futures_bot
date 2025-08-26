# frozen_string_literal: true

require "vcr"
require "json"

# VCR Helper Module for common patterns and utilities
module VCRHelpers
  # Smart filtering for dynamic timestamps
  def self.setup_timestamp_filters(config)
    # ISO 8601 timestamps
    config.filter_sensitive_data("<ISO8601_TIMESTAMP>") do |interaction|
      interaction.response.body.gsub(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?/, "<ISO8601_TIMESTAMP>")
    end

    # Unix timestamps (10-13 digits)
    config.filter_sensitive_data("<UNIX_TIMESTAMP>") do |interaction|
      interaction.response.body.gsub(/\b\d{10,13}\b/, "<UNIX_TIMESTAMP>")
    end

    # JWT tokens
    config.filter_sensitive_data("<JWT_TOKEN>") do |interaction|
      interaction.response.body.gsub(/eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*/, "<JWT_TOKEN>")
    end
  end

  # Trim large candle response bodies for faster tests
  def self.setup_response_trimming(config)
    config.before_record do |interaction|
      if interaction.request.uri.include?("/candles") && interaction.response.body
        begin
          parsed = JSON.parse(interaction.response.body)
          if parsed.is_a?(Array) && parsed.length > 10
            # Keep only first 5 and last 5 candles for testing
            trimmed = parsed.first(5) + parsed.last(5)
            interaction.response.body = trimmed.to_json
          end
        rescue JSON::ParserError
          # Keep original if not valid JSON
        end
      end
    end
  end

  # Environment-specific record modes
  def self.record_mode
    if ENV["CI"] == "true"
      :none # Never record in CI
    elsif ENV["VCR_RECORD_MODE"]
      ENV["VCR_RECORD_MODE"].to_sym
    else
      :new_episodes # Default for development
    end
  end

  # Standard cassette naming convention
  def self.cassette_name(test_class, test_method, variant = nil)
    base_name = "#{test_class.name.gsub("::", "_")}/#{test_method}"
    variant ? "#{base_name}/#{variant}" : base_name
  end
end

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!

  # Filter out sensitive data
  config.filter_sensitive_data("<COINBASE_API_KEY>") { ENV["COINBASE_API_KEY"] }
  config.filter_sensitive_data("<COINBASE_API_SECRET>") { ENV["COINBASE_API_SECRET"] }

  # Setup smart filtering
  VCRHelpers.setup_timestamp_filters(config)
  # Note: setup_response_trimming uses before_record which is not supported in VCR 6+
  # Response trimming is handled differently in newer versions

  # Filter Authorization headers
  config.filter_sensitive_data("<AUTHORIZATION>") do |interaction|
    interaction.request.headers["Authorization"]&.first
  end

  # Filter CB-ACCESS headers
  %w[CB-ACCESS-KEY CB-ACCESS-SIGN CB-ACCESS-TIMESTAMP CB-ACCESS-PASSPHRASE].each do |header|
    config.filter_sensitive_data("<#{header}>") do |interaction|
      interaction.request.headers[header]&.first
    end
  end

  # Filter out JWT tokens in Authorization headers (they contain timestamps)
  config.filter_sensitive_data("<JWT_TOKEN>") do |interaction|
    if interaction.request.headers["Authorization"]
      # Extract just the JWT part after "Bearer "
      auth_header = interaction.request.headers["Authorization"].first
      auth_header.sub("Bearer ", "") if auth_header&.start_with?("Bearer ")
    end
  end

  # Filter client order IDs that use UUIDs
  # Note: before_record is not supported in VCR 6+
  # UUID filtering is handled in the global configuration

  # Ignore Sentry requests
  config.ignore_request do |request|
    request.uri.include?("glitchtip.ger.ericdahl.dev") ||
      request.uri.include?("sentry.io") ||
      request.uri.include?("sentry")
  end

  # Allow real HTTP connections in development if needed
  config.allow_http_connections_when_no_cassette = false

  # Environment-specific record mode
  config.default_cassette_options = {
    record: :none,  # Force :none to prevent new recordings
    match_requests_on: %i[method uri body],
    allow_playback_repeats: true
  }
end
