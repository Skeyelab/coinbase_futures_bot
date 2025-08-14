# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../config/environment", __dir__)
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

# Maintain test schema
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

# Require support files
Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.use_transactional_fixtures = true

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include ActiveJob::TestHelper

  config.before(:each) do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  # Ensure a clean slate for domain tables between examples to avoid
  # cross-test interference when external data may exist in the DB.
  config.before(:each) do
    begin
      Candle.delete_all
      TradingPair.delete_all
      Tick.delete_all
      SentimentEvent.delete_all
      SentimentAggregate.delete_all
    rescue ActiveRecord::StatementInvalid
      # If tables are missing in a particular environment, ignore
    end
  end
end
