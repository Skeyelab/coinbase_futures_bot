# frozen_string_literal: true

module Funding
  # The single source of truth for perp funding over a hold (issue #391).
  #
  # Before this, funding lived in four disconnected places: the live-snapshotted
  # FundingRate rows (written, never read), the signed CostModel.funding_cost
  # primitive (no production caller), and two hardcoded 2 bps "adverse constant"
  # knobs — one in the simulator accrual, one in the strategy's break-even gate.
  # ADR 0002 makes it a hard guardrail that funding be "modeled ... rates
  # snapshotted live" before the go-live gate certifies any perp. A made-up
  # constant does not satisfy that.
  #
  # Schedule reads the observed FundingRate history for a product and answers two
  # questions from ONE object, so accrual and the gate can never silently desync:
  #
  #   * funding_cost(...)          — SIGNED realized funding over a closed hold,
  #                                  summed per funding boundary from observed
  #                                  rates (longs pay a positive rate, shorts
  #                                  collect it). Used by the simulator.
  #   * expected_forward_rate(...) — the MAGNITUDE of the upcoming funding rate,
  #                                  for the ex-ante break-even gate. Magnitude,
  #                                  not signed: the gate widens break-even
  #                                  conservatively and must not bank expected
  #                                  funding *income* into an entry decision.
  #
  # When no observation covers a boundary (backtest windows predating the
  # snapshot job — funding history is not reconstructible, see FundingRateSnapshot)
  # it falls back to the caller's constant and logs, so the fallback is never
  # silent. Both paths route their arithmetic through CostModel, keeping one
  # definition of "who pays funding".
  class Schedule
    # Build from the observed FundingRate history for a product. constant_* is the
    # fallback used for boundaries with no observation (preserves today's default
    # 2 bps/interval hourly behavior). Pass constant_rate_per_interval: nil to make
    # missing history contribute zero rather than a synthetic charge.
    def self.for(product_id:, constant_rate_per_interval: nil, constant_interval_seconds: 3600, logger: Rails.logger)
      observations = FundingRate.for_product(product_id).chronological.to_a
      new(product_id: product_id, observations: observations,
        constant_rate_per_interval: constant_rate_per_interval,
        constant_interval_seconds: constant_interval_seconds, logger: logger)
    end

    def initialize(product_id:, observations: [], constant_rate_per_interval: nil,
      constant_interval_seconds: 3600, logger: Rails.logger)
      @product_id = product_id
      # Sorted ascending by funding_time; each carries its own signed rate and
      # interval. Kept as plain structs so the schedule holds no DB reference.
      @observations = observations
        .map { |o| Observation.new(o.funding_time.to_time.utc, o.funding_rate.to_f, o.funding_interval_seconds.to_i) }
        .sort_by(&:funding_time)
      @constant_rate = constant_rate_per_interval&.to_f
      @constant_interval = constant_interval_seconds.to_i
      @logger = logger
      @fallback_warned = false
    end

    Observation = Struct.new(:funding_time, :rate, :interval_seconds)

    # Any funding to model at all? False when there is neither history nor a
    # constant — in which case the simulator/gate treat funding as free.
    def active?
      observed? || (@constant_rate&.positive? || false)
    end

    def observed?
      @observations.any?
    end

    # The funding interval in seconds: the most recently observed interval when we
    # have history (the venue is authoritative), else the caller's constant.
    def interval_seconds
      (@observations.last&.interval_seconds&.positive? && @observations.last.interval_seconds) || @constant_interval
    end

    # SIGNED realized funding in dollars over (entry_time, exit_time], charged on
    # `notional`. Positive = a cost to the position; negative = funding collected.
    # Summed per funding boundary the hold crossed, each priced at that boundary's
    # observed rate (or the constant fallback), so a varying-rate hold composes
    # correctly. Every dollar flows through CostModel.funding_cost.
    def funding_cost(notional:, side:, entry_time:, exit_time:)
      return 0.0 unless active?

      interval = interval_seconds
      total = 0.0
      used_fallback = false
      each_boundary(entry_time, exit_time, interval) do |boundary_epoch|
        rate = observed_rate_at(Time.at(boundary_epoch).utc)
        if rate.nil?
          rate = @constant_rate
          used_fallback = true
          next if rate.nil?
        end
        # One aligned boundary per call: a single-interval window ending on it.
        total += CostModel.funding_cost(
          notional: notional, side: side,
          entry_time: Time.at(boundary_epoch - interval).utc,
          exit_time: Time.at(boundary_epoch).utc,
          rate: rate, interval: interval
        )
      end
      warn_fallback!(entry_time, exit_time) if used_fallback
      total
    end

    # MAGNITUDE of the upcoming funding rate per interval, for the ex-ante gate:
    # the most recent observation at/before `as_of` (a snapshot advertises the
    # NEXT funding), else the constant. abs() because the gate is a conservative
    # break-even widening — it does not price in expected funding income.
    def expected_forward_rate(as_of: nil)
      obs = latest_observation_at(as_of)
      rate = obs&.rate || @constant_rate
      rate ? rate.abs : 0.0
    end

    private

    # Yields each epoch-aligned funding boundary in (entry, exit], matching
    # CostModel.funding_intervals_crossed so accrual boundaries and this iteration
    # can never disagree.
    def each_boundary(entry_time, exit_time, interval)
      return unless interval.positive?

      entry_epoch = entry_time.to_i
      exit_epoch = exit_time.to_i
      return if exit_epoch <= entry_epoch

      first_index = (entry_epoch / interval) + 1
      last_index = exit_epoch / interval
      (first_index..last_index).each { |i| yield i * interval }
    end

    # Most recent observed rate effective at `time` (funding_time <= time). Nil
    # when `time` precedes all history, so the caller can fall back explicitly.
    def observed_rate_at(time)
      obs = latest_observation_at(time)
      obs&.rate
    end

    def latest_observation_at(time)
      return @observations.last if time.nil?

      cutoff = time.to_time.utc
      # Observations are sorted ascending; take the last one at/before cutoff.
      @observations.reverse_each.find { |o| o.funding_time <= cutoff }
    end

    def warn_fallback!(entry_time, exit_time)
      return if @fallback_warned

      @fallback_warned = true
      @logger&.warn(
        "[Funding::Schedule] #{@product_id}: no observed funding rate for part of " \
        "#{entry_time.utc.iso8601}..#{exit_time.utc.iso8601}; fell back to the " \
        "constant #{(@constant_rate.to_f * 10_000).round(2)} bps/interval (issue #391)"
      )
    end
  end
end
