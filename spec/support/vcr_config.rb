# frozen_string_literal: true

# Additional VCR configuration for test separation and performance
module VCRConfig
  # Configure fast vs slow test separation
  def self.setup_test_tags
    RSpec.configure do |config|
      # Tag VCR tests appropriately
      config.before(:each, :vcr_fast) do
        # Use existing cassettes only, no network calls
        VCR.configure do |vcr_config|
          vcr_config.default_cassette_options[:record] = :none
          vcr_config.default_cassette_options[:allow_playback_repeats] = true
        end
      end

      config.before(:each, :vcr_slow) do
        # Allow new episodes for comprehensive testing
        VCR.configure do |vcr_config|
          vcr_config.default_cassette_options[:record] = :new_episodes
          vcr_config.default_cassette_options[:allow_playback_repeats] = false
        end
      end

      # Auto-tag integration tests as slow
      config.before(:each, type: :integration) do
        VCR.configure do |vcr_config|
          vcr_config.default_cassette_options[:record] = :new_episodes
        end
      end

      # Auto-tag service/job tests for appropriate speed
      config.before(:each, type: :service) do |example|
        # Service tests with API calls are slow by default
        if example.metadata[:vcr] || example.description.include?("API")
          example.metadata[:vcr_slow] = true unless example.metadata[:vcr_fast]
        end
      end

      config.before(:each, type: :job) do |example|
        # Job tests are typically integration tests
        example.metadata[:vcr_slow] = true unless example.metadata[:vcr_fast]
      end
    end
  end

  # Setup for CI environment
  def self.setup_ci_config
    return unless ENV["CI"] == "true"

    VCR.configure do |config|
      # In CI, never record new cassettes
      config.default_cassette_options[:record] = :none
      
      # Allow playback repeats for better test reliability
      config.default_cassette_options[:allow_playback_repeats] = true
      
      # Fail fast if cassette missing in CI
      config.default_cassette_options[:erb] = true
      
      # More strict matching in CI
      config.default_cassette_options[:match_requests_on] = [
        :method, :uri, :body, :headers
      ]
    end
  end

  # Setup for development environment
  def self.setup_development_config
    return if ENV["CI"] == "true"

    VCR.configure do |config|
      # More lenient matching for development
      config.default_cassette_options[:match_requests_on] = [
        :method, :uri, :body
      ]
      
      # Allow new episodes by default
      config.default_cassette_options[:record] = :new_episodes
      
      # Helpful warnings for missing cassettes
      config.before_record do |interaction|
        puts "📼 Recording VCR interaction: #{interaction.request.method.upcase} #{interaction.request.uri}"
      end
    end
  end
end

# Apply configurations
VCRConfig.setup_test_tags
VCRConfig.setup_ci_config
VCRConfig.setup_development_config