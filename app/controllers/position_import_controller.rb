# frozen_string_literal: true

class PositionImportController < ActionController::Base
  layout "application"

  # In API-only apps, CSRF/session may not be configured; skip for this simple UI
  skip_forgery_protection

  before_action :require_positions_basic_auth

  def index
    @positions = Position.open.order(:created_at)
    @import_service = PositionImportService.new
  end

  def import
    @import_service = PositionImportService.new
    @result = @import_service.import_positions_from_coinbase

    redirect_to position_import_index_path,
      notice: "Import complete! #{@result[:imported]} imported, #{@result[:updated]} updated"
  rescue => e
    redirect_to position_import_index_path, alert: "Import failed: #{e.message}"
  end

  def replace
    @import_service = PositionImportService.new
    @result = @import_service.import_and_replace

    redirect_to position_import_index_path,
      notice: "Replacement complete! Cleared #{@result[:cleared]}, imported #{@result[:imported]}"
  rescue => e
    redirect_to position_import_index_path, alert: "Replacement failed: #{e.message}"
  end

  def test_connection
    @client = Coinbase::Client.new
    @auth_result = @client.test_auth
    @positions = @client.futures_positions if @auth_result[:advanced_trade][:ok]
  rescue => e
    @error = e.message
  end

  private

  def require_positions_basic_auth
    return if Rails.env.development?

    authenticate_or_request_with_http_basic("Positions") do |username, password|
      username == ENV["POSITIONS_AUTH_USER"] && password == ENV["POSITIONS_AUTH_PASS"]
    end
  end
end
