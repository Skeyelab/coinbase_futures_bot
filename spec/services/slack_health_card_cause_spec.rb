# frozen_string_literal: true

require "rails_helper"

# Issue #536: the card showed "Warning" beside four green checks, because the
# checks that DECIDE the verdict were never rendered.
RSpec.describe SlackNotificationService, "health card names its cause (issue #536)" do
  def card(health_data)
    described_class.send(:format_health_message, health_data)
  end

  def field_titles(msg) = msg[:attachments].first[:fields].map { |f| f[:title] }

  let(:warning_data) do
    {
      overall_health: "warning",
      database: true, coinbase_api: true, background_jobs: true,
      websocket_connections: 1,
      portfolio_exposure: {
        healthy: false,
        warnings: ["Day trading exposure: 71.6% (max: 50.0%)"]
      },
      day_trading_positions: {healthy: true},
      swing_positions: {healthy: true}
    }
  end

  it "renders the failing check and its reason" do
    msg = card(warning_data)

    expect(field_titles(msg)).to include("Portfolio exposure")
    values = msg[:attachments].first[:fields].map { |f| f[:value].to_s }
    expect(values.join(" ")).to include("Day trading exposure: 71.6%")
  end

  it "does not add noise to a healthy card" do
    msg = card(warning_data.merge(overall_health: "healthy"))

    expect(field_titles(msg)).not_to include("Portfolio exposure")
  end

  it "omits checks that are passing" do
    msg = card(warning_data)

    expect(field_titles(msg)).not_to include("Day trading positions")
    expect(field_titles(msg)).not_to include("Swing positions")
  end

  it "still says something when a check fails without a warnings array" do
    msg = card(warning_data.merge(portfolio_exposure: {healthy: false}))

    values = msg[:attachments].first[:fields].map { |f| f[:value].to_s }
    expect(values).to include("unhealthy")
  end
end
