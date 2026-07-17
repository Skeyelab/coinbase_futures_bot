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

  context "sentiment health" do
    def sym(name, z, count, window = "15m")
      Sentiment::Snapshot::SymbolSnapshot.new(name, z, count, window, Time.now)
    end

    def snapshot(symbols:, sources:, stale:)
      Sentiment::Snapshot::Result.new(symbols, Time.now, Time.now, sources, stale)
    end

    let(:data) do
      {
        latest_futures_tick_at: Time.zone.parse("2026-06-08 14:30:00"),
        last_eval_at: Time.zone.parse("2026-06-08 14:29:00"),
        enabled_contract_count: 2,
        sentiment: snapshot(
          symbols: [sym("OIL-USD", -0.4, 3)],
          sources: [{name: "CoinDesk", enabled: true}, {name: "CryptoPanic", enabled: false}],
          stale: false
        )
      }
    end

    it "shows sentiment per enabled symbol" do
      output = panel.render

      expect(output).to include("Sentiment")
      expect(output).to include("OIL-USD").and include("z=-0.4").and include("3/15m")
    end

    it "shows sentiment source health" do
      output = panel.render

      expect(output).to include("CoinDesk").and include("CryptoPanic")
    end

    it "shows the enabled contract count" do
      expect(panel.render).to include("Enabled contracts").and include("2")
    end

    it "does not flag fresh sentiment as stale" do
      expect(panel.render).not_to match(/stale/i)
    end

    it "flags stale sentiment" do
      data[:sentiment] = snapshot(
        symbols: [sym("OIL-USD", -0.4, 3)],
        sources: [{name: "CoinDesk", enabled: true}],
        stale: true
      )

      expect(panel.render).to match(/stale/i)
    end
  end
end
