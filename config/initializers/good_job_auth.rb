unless Rails.env.local?
  GoodJob::Engine.middleware.use(Rack::Auth::Basic, "GoodJob") do |user, password|
    expected_username = ENV["POSITIONS_UI_USERNAME"].to_s
    expected_password = ENV["POSITIONS_UI_PASSWORD"].to_s

    expected_username.present? && expected_password.present? &&
      ActiveSupport::SecurityUtils.secure_compare(user.to_s, expected_username) &&
      ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected_password)
  end
end
