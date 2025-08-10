require "test_helper"

class HealthCheckTest < ActionDispatch::IntegrationTest
  def test_up_endpoint
    get "/up"
    assert_response :success
  end
end