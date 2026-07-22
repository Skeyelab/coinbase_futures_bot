# frozen_string_literal: true

require "rails_helper"

# Issue #397 (ADR 0003): CooldownPeriod blocks re-entry on a symbol for a
# configurable window after any position exit, so the bot does not immediately
# re-enter the conditions it just left.
RSpec.describe Trading::Protections::CooldownPeriod, type: :service do
  after { Trading::ProtectionLock.clear! }

  it "blocks both sides of the symbol after an exit" do
    described_class.record_exit(symbol: "BTC-PERP")

    expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long")).to be true
    expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "short")).to be true
  end

  it "does not block other symbols" do
    described_class.record_exit(symbol: "BTC-PERP")

    expect(Trading::Protections.blocked?(symbol: "ETH-PERP", side: "long")).to be false
  end

  it "the lock expires after the configured cooldown window" do
    described_class.record_exit(symbol: "BTC-PERP", cooldown_seconds: 120)

    lock = Trading::ProtectionLock.active.first
    expect(lock["source"]).to eq("CooldownPeriod")
    expect(Time.parse(lock["expires_at"])).to be_within(5).of(120.seconds.from_now)
  end

  it "does not block once the cooldown has elapsed" do
    described_class.record_exit(symbol: "BTC-PERP", cooldown_seconds: -1)

    expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long")).to be false
  end
end
