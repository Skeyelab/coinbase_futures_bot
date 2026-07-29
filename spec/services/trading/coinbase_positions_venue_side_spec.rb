# frozen_string_literal: true

require "rails_helper"

# Dry-run must not accept an order the venue would reject. That parity break is
# what hid #577: two clean rehearsals passed minutes before the first live order
# came back `invalid value for enum field side: "LONG"`, because simulate_order
# validates nothing about the side while the real endpoint validates an enum.
#
# A simulator more permissive than production is worse than no simulator — it
# certifies orders that cannot be placed.
RSpec.describe Trading::CoinbasePositions, "dry-run/live side parity", type: :service do
  subject(:service) { described_class.new(logger: Logger.new(IO::NULL)) }

  it "refuses a side the venue would reject, in dry-run as in live" do
    expect {
      service.send(:build_order_body, product_id: "BIP-20DEC30-CDE", side: "sideways",
        size: "1", type: :market)
    }.to raise_error(ArgumentError, /side must be/)
  end

  it "translates every accepted vocabulary to the venue enum before it leaves" do
    ["LONG", :long, "long", "BUY", :buy].each do |input|
      body = service.send(:build_order_body, product_id: "BIP-20DEC30-CDE", side: input,
        size: "1", type: :market)
      expect(body["side"]).to eq("BUY")
    end

    ["SHORT", :short, "short", "SELL", :sell].each do |input|
      body = service.send(:build_order_body, product_id: "BIP-20DEC30-CDE", side: input,
        size: "1", type: :market)
      expect(body["side"]).to eq("SELL")
    end
  end
end
