# frozen_string_literal: true

# Start SimpleCov before loading any application code
if ENV["COVERAGE"] == "true"
  require "simplecov"
  require "simplecov-json"

  SimpleCov.start "rails" do
    # Enable branch coverage first
    enable_coverage :branch

    # Coverage thresholds
    minimum_coverage line: 90
    minimum_coverage branch: 80

    # Output formats
    formatter SimpleCov::Formatter::MultiFormatter.new([
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::JSONFormatter
    ])

    # Coverage groups for organized reporting
    add_group "Models", "app/models"
    add_group "Controllers", "app/controllers"
    add_group "Services", "app/services"
    add_group "Jobs", "app/jobs"
    add_group "Lib", "lib"
    add_group "Config", "config"

    # Files to exclude from coverage
    add_filter "/spec/"
    add_filter "/test/"
    add_filter "/vendor/"
    add_filter "/config/"
    add_filter "/db/"
    add_filter "app/channels/application_cable/"
    add_filter "app/jobs/application_job.rb"
    add_filter "app/mailers/application_mailer.rb"
    add_filter "app/models/application_record.rb"

    # Track files with no tests
    track_files "{app,lib}/**/*.rb"
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Configure random order execution with seed reporting
  config.order = :random

  # Print the seed for reproducible test runs
  Kernel.srand config.seed
end
