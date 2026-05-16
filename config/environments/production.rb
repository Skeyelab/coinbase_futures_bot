require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # config.public_file_server.enabled = false

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch("RAILS_ASSUME_SSL", true))

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch("RAILS_FORCE_SSL", true))

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = {redirect: {exclude: ->(request) { request.path == "/up" }}}

  # Log to STDOUT by default
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Silence health check noise in logs.
  config.silence_healthcheck_path = "/up"

  # GoodJob runs in external mode in production (separate worker process).
  config.active_job.queue_adapter = :good_job
  config.good_job.execution_mode = :external

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [:id]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # Driven by env so no code change is needed per deployment.
  app_host = ENV["APP_HOST"].presence
  config.hosts << app_host if app_host
  ENV.fetch("RAILS_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:blank?).each do |h|
    config.hosts << h
  end

  # Always exclude /up from host authorization so the healthcheck works.
  config.host_authorization = {exclude: ->(request) { request.path == "/up" }}
end
