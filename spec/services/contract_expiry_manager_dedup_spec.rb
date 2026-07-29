# frozen_string_literal: true

require "rails_helper"

# Margin-warning dedup (issue #561, fourth instance of the alert-a-state-forever
# shape from #548/#557): a position near expiry is a state that persists for
# days, and every scheduled run re-announced it. Per position+reason, re-alert
# at most once per 24h.
RSpec.describe ContractExpiryManager, "margin warning dedup", type: :service do
  let(:logger) { double("logger", info: nil, warn: nil, error: nil) }
  let(:positions_service) { double("positions_service") }
  let(:lifecycle) { double("lifecycle") }
  let(:slack_service) { double("slack_service", alert: nil) }
  let(:expiry_manager) { described_class.new(logger: logger) }

  before do
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
    allow(Trading::PositionLifecycle).to receive(:new).and_return(lifecycle)
    stub_const("SlackNotificationService", slack_service)
    travel_to Time.utc(2025, 8, 25, 12, 0, 0) # Monday, August 25, 2025
  end

  after { travel_back }

  # 5 days out on Aug 25 -> "Expiry within 1 week" tier; stays in the same tier
  # (same reason) through Aug 26, so a 25h re-run isolates the time window from
  # a reason change.
  let!(:position) { create(:position, product_id: "BIT-30AUG25-CDE", status: "OPEN") }

  it "posts the warning the first time a position enters the window" do
    expiry_manager.check_margin_requirements_near_expiry(7)

    expect(slack_service).to have_received(:alert).with(
      "warning", "Margin Warning Near Expiry", /BIT-30AUG25-CDE/
    ).once
  end

  it "does not re-post for the same position+reason within 24h" do
    expiry_manager.check_margin_requirements_near_expiry(7)
    expiry_manager.check_margin_requirements_near_expiry(7)

    expect(slack_service).to have_received(:alert).once
  end

  it "still returns the full warning list even when the alert is deduped" do
    expiry_manager.check_margin_requirements_near_expiry(7)
    result = expiry_manager.check_margin_requirements_near_expiry(7)

    expect(result.size).to eq(1)
    expect(result.first[:position]).to eq(position)
  end

  it "re-alerts after 24h have elapsed" do
    expiry_manager.check_margin_requirements_near_expiry(7)

    travel 25.hours
    expiry_manager.check_margin_requirements_near_expiry(7)

    expect(slack_service).to have_received(:alert).twice
  end

  it "re-alerts immediately when the reason changes for the same position" do
    expiry_manager.check_margin_requirements_near_expiry(7)

    # Aug 28 -> 2 days out -> "Expiry within 3 days" tier: a new, more urgent
    # reason must not be swallowed by the previous tier's dedup record.
    travel_to Time.utc(2025, 8, 28, 12, 0, 0)
    expiry_manager.check_margin_requirements_near_expiry(7)

    expect(slack_service).to have_received(:alert).twice
  end

  it "posts only the not-yet-notified positions when others are deduped" do
    expiry_manager.check_margin_requirements_near_expiry(7)

    create(:position, product_id: "BIT-29AUG25-CDE", status: "OPEN")
    expiry_manager.check_margin_requirements_near_expiry(7)

    expect(slack_service).to have_received(:alert).with(
      "warning", "Margin Warning Near Expiry",
      satisfy { |msg| msg.include?("BIT-29AUG25-CDE") && !msg.include?("BIT-30AUG25-CDE") }
    ).once
  end
end
