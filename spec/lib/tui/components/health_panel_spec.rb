# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::Components::HealthPanel do
  subject(:panel) { described_class.new(data: data, rtm_status: rtm_status) }

  let(:data) do
    {
      latest_futures_tick_at: Time.zone.parse("2026-06-08 14:30:00"),
      last_eval_at: Time.zone.parse("2026-06-08 14:29:00")
    }
  end

  let(:rtm_status) do
    {
      active: true,
      futures_product_ids: ["NOL-19JUN26-CDE"],
      spot_product_ids: [],
      good_job_pending: 0
    }
  end

  it "renders monitoring status" do
    output = panel.render

    expect(output).to include("Real-time monitoring")
    expect(output).to include("ON")
    expect(output).to include("NOL-19JUN26-CDE")
  end

  it "renders an operations menu with dashboard actions" do
    output = panel.render

    expect(output).to include("Operations")
    expect(output).to include("[i] Import")
    expect(output).to include("[c] Close")
    expect(output).to include("[?] Menu")
  end
end
