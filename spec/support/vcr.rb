# frozen_string_literal: true

require "vcr"
require "json"

# VCR Helper Module for common patterns and utilities
module VCRHelpers
  # Smart filtering for dynamic timestamps
  def self.setup_timestamp_filters(config)
    # Remove all timestamp filtering from response bodies - this was corrupting JSON data
    # The timestamps in response bodies should be preserved as they're part of the actual data

    # Only filter sensitive data from headers, not response bodies
    # ISO 8601 timestamps and Unix timestamps in response bodies are actual data, not sensitive
    # config.filter_sensitive_data('<ISO8601_TIMESTAMP>') do |interaction|
    #   interaction.response.body.gsub(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?/, '<ISO8601_TIMESTAMP>')
    # end

    # JWT tokens - disabled due to response body corruption issues
    # TODO: Re-enable with more careful filtering that doesn't corrupt JSON responses
    # config.filter_sensitive_data("<JWT_TOKEN>") do |interaction|
    #   interaction.request.headers["Authorization"]&.first&.gsub(/eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*/, "<JWT_TOKEN>") || ""
    # end
  end

  # Trim large response bodies for faster tests
  def self.setup_response_trimming(config)
    config.before_record do |interaction|
      VCRHelpers.trim_large_responses(interaction)
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

  # Custom request matcher that ignores timestamp parameters
  def self.uri_without_timestamps(uri)
    return uri unless uri.is_a?(String)

    # Parse the URI and remove timestamp-related query parameters
    parsed_uri = URI.parse(uri)
    return uri unless parsed_uri.query

    params = URI.decode_www_form(parsed_uri.query)
    filtered_params = params.reject do |key, _value|
      key.downcase.include?("start") || key.downcase.include?("end") || key.downcase.include?("time")
    end

    parsed_uri.query = URI.encode_www_form(filtered_params) unless filtered_params.empty?
    parsed_uri.to_s
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
  # NOTE: setup_response_trimming uses before_record which is not supported in VCR 6+
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

  # Ignore external service requests
  config.ignore_request do |request|
    request.uri.include?("glitchtip.ger.ericdahl.dev") ||
      request.uri.include?("sentry.io") ||
      request.uri.include?("sentry") ||
      request.uri.include?("slack.com") ||
      request.uri.include?("hooks.slack.com")
  end

  # Allow real HTTP connections in development if needed
  config.allow_http_connections_when_no_cassette = false

  # Custom request matcher that ignores timestamp parameters
  config.register_request_matcher :uri_without_timestamps do |request1, request2|
    VCRHelpers.uri_without_timestamps(request1.uri) == VCRHelpers.uri_without_timestamps(request2.uri)
  end

  # Environment-specific record mode
  config.default_cassette_options = {
    record: VCRHelpers.record_mode,
    match_requests_on: %i[method uri_without_timestamps],
    allow_playback_repeats: true,
    preserve_exact_body_bytes: false, # Allow some flexibility
    update_content_length_header: false # Prevent hanging on content length issues
  }
end
