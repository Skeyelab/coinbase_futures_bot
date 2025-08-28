if Rails.env.test?
  # Remove HostAuthorization middleware in test environment
  Rails.application.config.after_initialize do
    Rails.application.middleware.delete ActionDispatch::HostAuthorization
  end
end
