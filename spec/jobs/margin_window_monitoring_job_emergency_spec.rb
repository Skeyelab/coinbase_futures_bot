# frozen_string_literal: true

require "rails_helper"

# Issue #554: three defects in the emergency margin closure path — the path
# that exists to prevent a forced liquidation. Per the #551 post-mortem, these
# examples deliberately use positions with DIFFERENT contract economics so a
# spec cannot pass by accident of symmetric fixtures.
RSpec.describe MarginWindowMonitoringJob, "emergency margin closure (#554)" do
  let(:job) { described_class.new }

  before { job.instance_variable_set(:@logger, Rails.logger) }

  describe "closure order" do
    it "closes the position with the LARGEST margin requirement first, not the smallest contract count" do
      # BIP: 1 contract, tiny notional (~$6 requirement).
      # NOL: 3 contracts, large notional (~$279 requirement).
      # The old contract-count sort ("smallest first") picks BIP here — fewest
      # contracts, least margin freed — backwards for an emergency whose
      # purpose is restoring buffer. Deliberately arranged so the count order
      # and the requirement order DISAGREE; a fixture where they agree passes
      # either way (the #551 trap).
      bip = create(:position, product_id: "BIP-20DEC30-CDE", side: "LONG",
        size: 1, status: "OPEN")
      nol = create(:position, product_id: "NOL-19AUG26-CDE", side: "SHORT",
        size: 3, status: "OPEN")

      violations = [
        {position_id: bip.id, product_id: bip.product_id, size: 1, margin_requirement: 6.4},
        {position_id: nol.id, product_id: nol.product_id, size: 3, margin_requirement: 279.0}
      ]

      closed = []
      allow(PositionCloseJob).to receive(:perform_now) { |position_id:, **| closed << position_id }

      job.send(:close_positions_for_margin_emergency, violations)

      # Closes ONE then breaks to reassess — and that one must be the largest
      # margin requirement.
      expect(closed).to eq([nol.id])
    end
  end

  describe "margin rate selection" do
    let(:position) { create(:position, product_id: "NOL-19AUG26-CDE", side: "SHORT", size: 1, status: "OPEN") }

    before { allow(Trading::NotionalCap).to receive(:notional_for).and_return(1000.0) }

    def requirement_for(window_type)
      window = window_type.nil? ? {} : {"margin_window" => {"margin_window_type" => window_type}}
      job.send(:calculate_position_margin_requirement, position, window)
    end

    it "applies the 20% overnight rate for the REAL API enum, not just the bare label" do
      # Live health payloads carry FCM_MARGIN_WINDOW_TYPE_OVERNIGHT; the old
      # comparison matched only "OVERNIGHT_MARGIN", so the overnight branch
      # was unreachable even when the endpoint worked.
      expect(requirement_for("FCM_MARGIN_WINDOW_TYPE_OVERNIGHT")).to eq(200.0)
      expect(requirement_for("OVERNIGHT_MARGIN")).to eq(200.0)
    end

    it "fails CONSERVATIVE (20%) when the window is unknown or unavailable" do
      # The margin-window endpoint 403s on this account, so the window
      # resolves to UNKNOWN_MARGIN — the defence must not silently assume the
      # cheaper intraday rate when it cannot know.
      expect(requirement_for("UNKNOWN_MARGIN")).to eq(200.0)
      expect(requirement_for(nil)).to eq(200.0)
    end

    it "applies the 10% intraday rate only when the window is explicitly intraday" do
      expect(requirement_for("INTRADAY_MARGIN")).to eq(100.0)
      expect(requirement_for("FCM_MARGIN_WINDOW_TYPE_INTRADAY")).to eq(100.0)
    end
  end
end

RSpec.describe PositionCloseJob, "emergency margin closures retry (#554)" do
  it "treats emergency_margin_violation as critical" do
    expect(described_class::CRITICAL_REASONS).to include("emergency_margin_violation")
  end

  it "schedules a retry when an emergency margin closure fails" do
    position = create(:position, product_id: "BIP-20DEC30-CDE", side: "LONG",
      size: 1, status: "OPEN")
    lifecycle = instance_double(Trading::PositionLifecycle)
    allow(Trading::PositionLifecycle).to receive(:new).and_return(lifecycle)
    allow(lifecycle).to receive(:close)
      .and_return(Trading::PositionLifecycle::Result.new(success: false, close_price: nil,
        reason: "emergency_margin_violation", fallback: false))

    expect(described_class).to receive(:set).with(wait: 30.seconds).and_call_original

    described_class.perform_now(position_id: position.id, reason: "emergency_margin_violation")
  end
end
