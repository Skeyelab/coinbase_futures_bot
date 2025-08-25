# frozen_string_literal: true

# Additional VCR helper methods for consistent usage across tests
module VCRTestHelpers
  # Use VCR with automatic cassette naming
  def with_vcr_cassette(name = nil, options = {}, &block)
    cassette_name = name || auto_cassette_name
    VCR.use_cassette(cassette_name, options, &block)
  end

  # Automatically generate cassette names from test context
  def auto_cassette_name
    example = RSpec.current_example
    return "unknown_test" unless example

    test_class = example.example_group.described_class&.name || "AnonymousClass"
    test_method = example.description.parameterize(separator: "_")

    VCRHelpers.cassette_name(test_class, test_method)
  end

  # Fast VCR for tests that don't need real API responses
  def with_fast_vcr(name = nil, &block)
    options = {
      record: :none,
      allow_playback_repeats: true,
      match_requests_on: [:method, :uri]
    }
    with_vcr_cassette(name, options, &block)
  end

  # VCR for integration tests with full recording
  def with_integration_vcr(name = nil, &block)
    options = {
      record: :new_episodes,
      match_requests_on: [:method, :uri, :body],
      allow_playback_repeats: false
    }
    with_vcr_cassette(name, options, &block)
  end

  # VCR for API tests with response trimming
  def with_api_vcr(name = nil, trim_responses: true, &block)
    options = {
      record: VCRHelpers.record_mode,
      match_requests_on: [:method, :uri, :body]
    }

    if trim_responses
      options[:before_record] = ->(interaction) do
        VCRHelpers.trim_large_responses(interaction)
      end
    end

    with_vcr_cassette(name, options, &block)
  end

  # Create a fresh cassette (delete existing)
  def with_fresh_vcr_cassette(name = nil, &block)
    cassette_name = name || auto_cassette_name
    cassette_path = File.join(VCR.configuration.cassette_library_dir, "#{cassette_name}.yml")

    FileUtils.rm_f(cassette_path) if File.exist?(cassette_path)

    options = {record: :new_episodes}
    VCR.use_cassette(cassette_name, options, &block)
  end
end

# Extend VCRHelpers with additional utility methods
module VCRHelpers
  # Trim large responses for better test performance
  def self.trim_large_responses(interaction)
    return unless interaction.response.body

    # Trim candle data
    trim_candle_response(interaction) if interaction.request.uri.include?("/candles")

    # Trim products list
    trim_products_response(interaction) if interaction.request.uri.include?("/products")
  end

  # Cassette health check
  def self.cassette_healthy?(cassette_path)
    return false unless File.exist?(cassette_path)

    content = YAML.load_file(cassette_path)
    return false unless content.is_a?(Hash)
    return false unless content["http_interactions"]

    # Check for common issues
    interactions = content["http_interactions"]
    return false if interactions.empty?

    # Check for placeholder values that indicate filtering issues
    yaml_content = File.read(cassette_path)
    return false if yaml_content.include?("<TIMESTAMP>") && yaml_content.scan("<TIMESTAMP>").length > 50

    true
  rescue => e
    Rails.logger.warn "VCR cassette health check failed for #{cassette_path}: #{e.message}"
    false
  end

  # Get cassette expiration date
  def self.cassette_expired?(cassette_path, max_age_days = 30)
    return true unless File.exist?(cassette_path)

    File.mtime(cassette_path) < max_age_days.days.ago
  end

  # Clean up old or unhealthy cassettes
  def self.cleanup_cassettes!(max_age_days: 30, remove_unhealthy: true)
    cassette_dir = VCR.configuration.cassette_library_dir
    return 0 unless Dir.exist?(cassette_dir)

    removed_count = 0

    Dir.glob(File.join(cassette_dir, "**", "*.yml")).each do |cassette_path|
      should_remove = false
      reason = nil

      if cassette_expired?(cassette_path, max_age_days)
        should_remove = true
        reason = "expired (older than #{max_age_days} days)"
      elsif remove_unhealthy && !cassette_healthy?(cassette_path)
        should_remove = true
        reason = "unhealthy"
      end

      if should_remove
        File.delete(cassette_path)
        removed_count += 1
        Rails.logger.info "Removed #{reason} VCR cassette: #{cassette_path}"
      end
    end

    Rails.logger.info "VCR cleanup complete: removed #{removed_count} cassettes"
    removed_count
  end

  # Private helper methods for response trimming
  def self.trim_candle_response(interaction)
    parsed = JSON.parse(interaction.response.body)
    if parsed.is_a?(Array) && parsed.length > 10
      # Keep first 3, middle 2, and last 3 for representative sample
      middle_index = parsed.length / 2
      trimmed = parsed.first(3) +
        parsed[middle_index, 2] +
        parsed.last(3)
      interaction.response.body = trimmed.to_json
    end
  rescue JSON::ParserError
    # Keep original if not valid JSON
  end

  def self.trim_products_response(interaction)
    parsed = JSON.parse(interaction.response.body)
    if parsed.is_a?(Array) && parsed.length > 20
      # Keep first 10 and last 10 products
      trimmed = parsed.first(10) + parsed.last(10)
      interaction.response.body = trimmed.to_json
    end
  rescue JSON::ParserError
    # Keep original if not valid JSON
  end
end

# Include helpers in RSpec
RSpec.configure do |config|
  config.include VCRTestHelpers, type: :service
  config.include VCRTestHelpers, type: :job
  config.include VCRTestHelpers, type: :task
end
