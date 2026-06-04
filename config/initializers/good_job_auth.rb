GoodJob::Engine.middleware.use(Rack::Auth::Basic) do |user, password|
  unless Rails.env.local?
    ActiveSupport::SecurityUtils.secure_compare(
      user, ENV.fetch("GOOD_JOB_USERNAME", "ops")
    ) & ActiveSupport::SecurityUtils.secure_compare(
      password, ENV.fetch("GOOD_JOB_PASSWORD", "")
    )
  end
end
