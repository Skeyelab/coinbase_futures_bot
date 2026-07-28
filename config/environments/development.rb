require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Low-level cache store (Rails.cache): use an in-process memory store even when
  # HTTP/fragment caching is off. The trading bot's rate limiters (PhasedRateLimiter,
  # tick-driven signal/basis/arbitrage throttles) rely on Rails.cache; with the
  # Rails default :null_store they silently no-op and enqueue a job on nearly every
  # tick (~6.5k jobs/5min observed on the always-on box). memory_store is per-process
  # and cleared on restart, so it's safe for dev. Controller/view caching still
  # follows the rails dev:cache toggle below.
  config.cache_store = :memory_store
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.public_file_server.headers = {"Cache-Control" => "public, max-age=#{2.days.to_i}"}
  else
    config.action_controller.perform_caching = false
  end

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  config.action_mailer.default_url_options = {host: "localhost", port: 3000}

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Allow tunnel/proxy hosts for development so inbound webhooks (e.g. Slack slash
  # commands) reach the app: ngrok, Tailscale serve/funnel (*.ts.net), and any
  # hosts listed in RAILS_ALLOWED_HOSTS (comma-separated).
  config.hosts << "skeyelab.ngrok.io"
  config.hosts << /.*\.ngrok\.io/
  config.hosts << /.*\.ts\.net/
  ENV.fetch("RAILS_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:blank?).each do |h|
    config.hosts << h
  end

  # GoodJob runs inside Puma in dev — no separate process needed.
  config.good_job.execution_mode = :async

  # The always-on box runs the trading loops under systemd with no RAILS_ENV, so
  # they boot HERE, in development — where Rails logs to log/development.log and
  # journald therefore captures nothing but `puts` and crash backtraces. Seven
  # days of `journalctl --user -u cfb-realtime` contained zero logger lines while
  # a swallowed Order-write failure repeated in the file, unread.
  #
  # Opt-in rather than unconditional: `bin/rails server` already broadcasts to
  # stdout in development, and turning this on for everyone would double every
  # line for anyone working locally. The systemd units set it; laptops do not.
  # The level is set on the LOGGER, not only via config.log_level. A logger the
  # app constructs itself is born at DEBUG, and config.log_level does not
  # reliably reach it — measured on the box: with config.log_level = "info" set
  # exactly as below, cfb-realtime still emitted 17,619 lines in 60 seconds
  # (~294/sec), all ActiveRecord query logging, which is :debug. At ~150 bytes a
  # line that is ~3.3 GB/day against journald's 4 GB default cap: the trading
  # loop's own logs would evict themselves, and everything else on the box with
  # them, inside about a day. Setting Logger#level closes that.
  # The level must be a Logger SEVERITY CONSTANT set on the logger object.
  # Two things defeat the obvious spellings:
  #   * When config.logger is supplied, Rails uses it as-is and never applies
  #     config.log_level — that assignment only runs on the logger Rails builds
  #     itself. So config.log_level alone is inert here.
  #   * Logger#level = "info" (a String) does not coerce; the logger stays at
  #     DEBUG. Verified both, rather than assumed.
  if ENV["RAILS_LOG_TO_STDOUT"].present?
    level_name = ENV.fetch("RAILS_LOG_LEVEL", "info").upcase
    stdout_logger = ActiveSupport::TaggedLogging.logger($stdout)
    stdout_logger.level = ActiveSupport::Logger.const_get(level_name)
    config.logger = stdout_logger
    config.log_level = level_name.downcase.to_sym
  end
end
