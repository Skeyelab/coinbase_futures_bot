# frozen_string_literal: true

require "rails_helper"

# Issue #397 (ADR 0003): protection locks must run against an injectable store
# and an explicit clock so a backtest can evaluate the SAME protection logic on
# historical (simulated) time without touching the live bot_runtime_stats store.
RSpec.describe "Trading::ProtectionLock injectable store + clock", type: :service do
  let(:store) { Trading::ProtectionLock::MemoryStore.new }

  it "writes to and reads from the injected store, not the DB" do
    Trading::ProtectionLock.add(scope: "global", source: "MaxDrawdown",
      expires_at: Time.utc(2026, 1, 1, 12, 0, 0), store: store)

    expect(store.read.size).to eq(1)
    expect(BotRuntimeStat.find_by(key: Trading::ProtectionLock::STORE_KEY)).to be_nil
  end

  it "expires locks against the injected clock, not wall-clock" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", source: "CooldownPeriod",
      expires_at: Time.utc(2026, 1, 1, 12, 5, 0), store: store)

    # Simulated time before expiry -> blocked
    expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long",
      now: Time.utc(2026, 1, 1, 12, 1, 0), store: store)).to be true

    # Simulated time after expiry -> not blocked
    expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long",
      now: Time.utc(2026, 1, 1, 12, 6, 0), store: store)).to be false
  end

  it "CooldownPeriod records into the injected store on the simulated clock" do
    exit_time = Time.utc(2026, 1, 1, 12, 0, 0)
    Trading::Protections::CooldownPeriod.record_exit(symbol: "BTC-PERP",
      cooldown_seconds: 300, now: exit_time, store: store)

    expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long",
      now: exit_time + 100, store: store)).to be true
    expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long",
      now: exit_time + 400, store: store)).to be false
  end
end
