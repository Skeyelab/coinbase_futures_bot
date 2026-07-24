# frozen_string_literal: true

require "rails_helper"

RSpec.describe CostModel do
  describe ".taker_fee_rate" do
    # ADR 0002 retired the 15 bps dated-CDE number: perps are ~3 bps taker.
    it "defaults to 3 bps (perp taker)" do
      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
        expect(described_class.taker_fee_rate).to eq(0.0003)
      end
    end

    it "honors BACKTEST_TAKER_FEE_RATE" do
      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: "0.002") do
        expect(described_class.taker_fee_rate).to eq(0.002)
      end
    end
  end

  describe ".maker_fee_rate" do
    # ADR 0002: US perps charge 0% maker.
    it "defaults to 0 (perp maker)" do
      ClimateControl.modify(BACKTEST_MAKER_FEE_RATE: nil, MAKER_FEE_RATE: nil) do
        expect(described_class.maker_fee_rate).to eq(0.0)
      end
    end

    it "honors MAKER_FEE_RATE" do
      ClimateControl.modify(MAKER_FEE_RATE: "0.0002") do
        expect(described_class.maker_fee_rate).to eq(0.0002)
      end
    end
  end

  describe ".break_even_exit" do
    it "prices the exit where fees+slippage net to zero" do
      be = described_class.break_even_exit(entry_price: 100.0, fee_rate: 0.0003, slippage_rate: 0.0002)
      r = 0.0005
      expect(be).to be_within(1e-9).of(100.0 * (1.0 + r) / (1.0 - r))
    end

    # The ex-ante gate must also clear expected funding over the hold (issue
    # #391): a position that only breaks even on fees still loses to funding.
    it "widens the break-even exit to also clear an expected funding fraction" do
      base = described_class.break_even_exit(entry_price: 100.0, fee_rate: 0.0003)
      with_funding = described_class.break_even_exit(entry_price: 100.0, fee_rate: 0.0003, funding_rate: 0.0002)
      expect(with_funding).to be > base
      expect(with_funding).to be_within(1e-9).of(100.0 * (1.0 + 0.0003 + 0.0002) / (1.0 - 0.0003))
    end

    it "defaults funding_rate to 0 (break-even unchanged)" do
      expect(described_class.break_even_exit(entry_price: 100.0, fee_rate: 0.0003))
        .to be_within(1e-12).of(described_class.break_even_exit(entry_price: 100.0, fee_rate: 0.0003, funding_rate: 0.0))
    end
  end

  describe ".round_trip_cost" do
    it "sums per-side fees plus slippage on entry and exit notional" do
      cost = described_class.round_trip_cost(
        entry_price: 100.0, exit_price: 110.0, quantity: 2.0,
        fee_rate: 0.001, slippage_rate: 0.0005
      )
      expect(cost).to be_within(1e-9).of((100.0 + 110.0) * 2.0 * 0.0015)
    end

    it "applies the flat per-contract floor when contracts are given (issue #372)" do
      # Coinbase US futures: ~0.02%/contract with a $0.15/contract MINIMUM.
      # 2 contracts x $80 notional/side: proportional = $0.24/side; floor =
      # $0.30/side -> floor binds. Round trip = 2 x $0.30.
      cost = described_class.round_trip_cost(
        entry_price: 80.0, exit_price: 80.0, quantity: 2.0,
        fee_rate: 0.0015, contracts: 2
      )
      expect(cost).to be_within(1e-9).of(0.60)
    end

    it "keeps proportional fees when they exceed the floor" do
      # 2 contracts x $600 notional/side: proportional $1.80/side > $0.30 floor
      cost = described_class.round_trip_cost(
        entry_price: 600.0, exit_price: 600.0, quantity: 2.0,
        fee_rate: 0.0015, contracts: 2
      )
      expect(cost).to be_within(1e-9).of(3.60)
    end
  end

  describe ".min_fee_per_contract" do
    it "defaults to $0.15 and honors the env override" do
      ClimateControl.modify(TAKER_MIN_FEE_PER_CONTRACT: nil) do
        expect(described_class.min_fee_per_contract).to eq(0.15)
      end
      ClimateControl.modify(TAKER_MIN_FEE_PER_CONTRACT: "0.2") do
        expect(described_class.min_fee_per_contract).to eq(0.2)
      end
    end

    # ADR 0002: on BIP the $0.15/contract floor never binds ($659 notional x
    # 3 bps = $0.198 > $0.15). Guards against a future small-notional perp
    # silently inheriting the wrong geometry.
    it "is non-binding at BIP per-contract notional under perp taker fees" do
      bip_notional = 659.0
      side_proportional = bip_notional * described_class.taker_fee_rate
      expect(side_proportional).to be > described_class.min_fee_per_contract

      cost = described_class.round_trip_cost(
        entry_price: bip_notional, exit_price: bip_notional, quantity: 1.0,
        fee_rate: described_class.taker_fee_rate, contracts: 1
      )
      # Proportional wins on both sides; the floor is untouched.
      expect(cost).to be_within(1e-9).of(2 * side_proportional)
    end
  end

  # The 3 bps perp taker default is a published-schedule estimate (ADR 0002);
  # no perp has been executed yet, so nothing has validated it against real
  # commissions. This hook surfaces material drift once real perp fills exist.
  describe ".taker_fee_drift" do
    it "returns nil when the observed rate is within tolerance of the default" do
      # 3.5 bps observed vs 3 bps default = 16.7% drift, under the 50% tolerance.
      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
        expect(described_class.taker_fee_drift(observed_rate: 0.00035)).to be_nil
      end
    end

    it "reports drift when the observed rate diverges beyond tolerance" do
      # 9 bps observed vs 3 bps default = 200% drift.
      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
        drift = described_class.taker_fee_drift(observed_rate: 0.0009)
        expect(drift).to include(expected: 0.0003, observed: 0.0009)
        expect(drift[:relative_drift]).to be_within(1e-9).of(2.0)
      end
    end

    it "returns nil for non-positive inputs (nothing to compare)" do
      expect(described_class.taker_fee_drift(observed_rate: 0.0, expected_rate: 0.0003)).to be_nil
      expect(described_class.taker_fee_drift(observed_rate: 0.0003, expected_rate: 0.0)).to be_nil
    end

    it "honors an explicit tolerance" do
      # 16.7% drift is flagged when tolerance tightens to 10%.
      drift = described_class.taker_fee_drift(observed_rate: 0.00035, expected_rate: 0.0003, tolerance: 0.1)
      expect(drift[:relative_drift]).to be_within(1e-4).of(1.0 / 6.0)
    end
  end

  describe ".check_taker_fee_drift!" do
    let(:logger) { instance_double(Logger, warn: nil) }

    it "logs a warning and returns the drift when it exceeds tolerance" do
      drift = described_class.check_taker_fee_drift!(observed_rate: 0.0009, expected_rate: 0.0003, logger: logger)
      expect(drift[:observed]).to eq(0.0009)
      expect(logger).to have_received(:warn).with(/taker fee drift/i)
    end

    it "stays silent and returns nil when within tolerance" do
      expect(described_class.check_taker_fee_drift!(observed_rate: 0.00031, expected_rate: 0.0003, logger: logger)).to be_nil
      expect(logger).not_to have_received(:warn)
    end
  end

  describe ".funding_cost" do
    # Hourly funding boundaries are epoch-aligned (top of each hour).
    let(:interval) { 3600 }
    let(:rate) { 0.0001 } # 1 bp/interval
    let(:notional) { 10_000.0 }

    it "charges a long for each funding timestamp crossed during the hold" do
      # Held 08:30 -> 11:30 crosses 09:00, 10:00, 11:00 => 3 intervals.
      cost = described_class.funding_cost(
        notional: notional, side: :long,
        entry_time: Time.utc(2026, 7, 22, 8, 30), exit_time: Time.utc(2026, 7, 22, 11, 30),
        rate: rate, interval: interval
      )
      expect(cost).to be_within(1e-9).of(3 * rate * notional)
    end

    it "credits a short by the same magnitude (opposite sign)" do
      cost = described_class.funding_cost(
        notional: notional, side: :short,
        entry_time: Time.utc(2026, 7, 22, 8, 30), exit_time: Time.utc(2026, 7, 22, 11, 30),
        rate: rate, interval: interval
      )
      expect(cost).to be_within(1e-9).of(-3 * rate * notional)
    end

    it "charges nothing when no funding timestamp is crossed" do
      cost = described_class.funding_cost(
        notional: notional, side: :long,
        entry_time: Time.utc(2026, 7, 22, 8, 5), exit_time: Time.utc(2026, 7, 22, 8, 50),
        rate: rate, interval: interval
      )
      expect(cost).to eq(0.0)
    end

    # (entry, exit] — a boundary hit exactly at entry is NOT charged (position
    # only just opened), one hit exactly at exit IS charged. This half-open
    # rule composes without double-counting across candle steps.
    it "excludes a boundary at the entry instant and includes one at the exit instant" do
      cost = described_class.funding_cost(
        notional: notional, side: :long,
        entry_time: Time.utc(2026, 7, 22, 9, 0), exit_time: Time.utc(2026, 7, 22, 10, 0),
        rate: rate, interval: interval
      )
      # 09:00 excluded (entry), 10:00 included (exit) => exactly 1 interval.
      expect(cost).to be_within(1e-9).of(1 * rate * notional)
    end

    it "flips signs when the funding rate is negative (longs collect)" do
      cost = described_class.funding_cost(
        notional: notional, side: :long,
        entry_time: Time.utc(2026, 7, 22, 8, 30), exit_time: Time.utc(2026, 7, 22, 10, 30),
        rate: -rate, interval: interval
      )
      expect(cost).to be_within(1e-9).of(-2 * rate * notional)
    end

    it "honors a non-hourly funding interval" do
      eight_hours = 8 * 3600
      # Held 07:00 -> 33:00 (i.e. next day 09:00) crosses 08:00, 16:00, 24:00,
      # 32:00 boundaries => 4 intervals at an 8h cadence.
      cost = described_class.funding_cost(
        notional: notional, side: :long,
        entry_time: Time.utc(2026, 7, 22, 7, 0), exit_time: Time.utc(2026, 7, 23, 9, 0),
        rate: rate, interval: eight_hours
      )
      expect(cost).to be_within(1e-9).of(4 * rate * notional)
    end
  end
end
