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

    # PostHog: Track position import
    PostHog.capture(
      distinct_id: "system",
      event: "position_import_completed",
      properties: {mode: "import", imported: @result[:imported], updated: @result[:updated]}
    )

    redirect_to position_import_index_path,
      notice: "Import complete! #{@result[:imported]} imported, #{@result[:updated]} updated"
  rescue => e
    redirect_to position_import_index_path, alert: "Import failed: #{e.message}"
  end

  def replace
    @import_service = PositionImportService.new
    @result = @import_service.import_and_replace

    # PostHog: Track position replacement import
    PostHog.capture(
      distinct_id: "system",
      event: "position_import_completed",
      properties: {mode: "replace", cleared: @result[:cleared], imported: @result[:imported]}
    )

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

  # ADR 0005: this controller rewrites the `positions` table the entire risk
  # stack counts from — #replace clears it and re-imports — so authorization
  # fails closed. Two defects are fixed here:
  #
  #   1. `return if Rails.env.development?` skipped auth wholesale, so anyone
  #      who could reach a dev instance could clear the position book.
  #   2. Plain `==` on the credentials leaked comparison timing, and matched
  #      when both sides were nil, i.e. when nothing was configured.
  #
  # This mirrors positions_controller.rb#require_positions_basic_auth, the
  # reference implementation named by the ADR.
  def require_positions_basic_auth
    username = ENV["POSITIONS_AUTH_USER"].to_s
    password = ENV["POSITIONS_AUTH_PASS"].to_s

    unless username.present? && password.present?
      render plain: "Position import credentials not configured. Set POSITIONS_AUTH_USER and POSITIONS_AUTH_PASS.",
        status: :forbidden and return
    end

    authenticate_or_request_with_http_basic("Positions") do |u, p|
      ActiveSupport::SecurityUtils.secure_compare(u.to_s, username) &&
        ActiveSupport::SecurityUtils.secure_compare(p.to_s, password)
    end
  end
end
