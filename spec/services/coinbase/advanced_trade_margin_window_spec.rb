# frozen_string_literal: true

require "rails_helper"

# The dedicated /cfm/intraday/current_margin_window endpoint 403s for this
# account, so get_current_margin_window falls back to the futures balance
# summary. The old fallback classified the window as INTRADAY when the
# intraday_margin_window_measure key was present, else OVERNIGHT — and discarded
# the overnight measure entirely. For this account the balance summary carries
# NEITHER measure, so it fabricated a confident "OVERNIGHT_MARGIN" on every run,
# firing a false hourly Slack alert (overnight margin active at 11:30am ET).
#
# The fallback must not invent a window it can't determine: absent data =>
# UNKNOWN_MARGIN, which the monitor treats quietly (no alert).
RSpec.describe Coinbase::AdvancedTradeClient, "#get_current_margin_window fallback" do
  let(:client) { described_class.new }

  before do
    client.instance_variable_set(:@authenticated, true)
    allow(Rails.logger).to receive(:warn)
    # Force the 403 fallback path.
    err = Faraday::ClientError.new("forbidden")
    allow(err).to receive(:response).and_return({status: 403})
    allow(client).to receive(:authenticated_get).and_raise(err)
  end

  def stub_balance(summary)
    allow(client).to receive(:get_futures_balance_summary).and_return(summary)
  end

  it "returns UNKNOWN_MARGIN when neither measure is present (this account)" do
    stub_balance({})
    result = client.get_current_margin_window
    expect(result.dig("margin_window", "margin_window_type")).to eq("UNKNOWN_MARGIN")
    expect(result["_source"]).to eq("balance_summary_fallback")
  end

  it "classifies INTRADAY only when the intraday measure is actually present" do
    stub_balance({"intraday_margin_window_measure" => {"foo" => 1}})
    expect(client.get_current_margin_window.dig("margin_window", "margin_window_type"))
      .to eq("INTRADAY_MARGIN")
  end

  it "classifies OVERNIGHT only when the overnight measure is present and intraday is absent" do
    stub_balance({"overnight_margin_window_measure" => {"foo" => 1}})
    expect(client.get_current_margin_window.dig("margin_window", "margin_window_type"))
      .to eq("OVERNIGHT_MARGIN")
  end
end
