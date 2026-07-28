# frozen_string_literal: true

module Trading
  module ExecutionCalibration
    # The #486 harness: 20 forced round trips on BIP, one contract each, half
    # taker-entry and half maker-entry, to MEASURE what execution costs.
    #
    # This is metrology, not strategy. Nothing here consults a signal, and no
    # inference about edge may be drawn from 20 forced trades. What it buys is
    # the one number ADR 0002's whole venue thesis rests on — a ~3 bps perp
    # taker rate that has never been validated against a single real fill — plus
    # the maker fill rate the +22 bps upgrade assumes and nobody has observed.
    #
    # SAFETY
    #
    # Dry-run is the default and three INDEPENDENT gates stand between this and
    # a real order: the caller must pass live:, LIVE_TRADING_CONFIRMED must be
    # "1" in the environment, and the operator must type an exact phrase. Any
    # one missing refuses the run outright rather than quietly degrading, so a
    # half-configured live attempt is never mistaken for a rehearsal.
    #
    # Every order goes through Trading::CoinbasePositions and every close
    # through Trading::PositionLifecycle. No second order path is opened here —
    # that is what keeps the halt assertion, the paper-default gate, the
    # cooldown and the loss caps in force for these orders too.
    class Runner
      CONFIRMATION_PHRASE = "CALIBRATE BIP LIVE"
      # BIP only, hardcoded (#486). Not a parameter with a default: a typo that
      # pointed this at a dated contract would spend money on the wrong venue.
      INSTRUMENT_PREFIX = "BIP"
      DEFAULT_ROUND_TRIPS = 20
      DEFAULT_HOLD_SECONDS = 30
      # How long to wait for a taker entry to appear in the fills feed. A market
      # IOC that has not filled in this long has not filled.
      TAKER_FILL_TIMEOUT_SECONDS = 15
      RECONCILIATION_TOLERANCE = 0.10

      def initialize(product_id: nil, round_trips: DEFAULT_ROUND_TRIPS, hold_seconds: DEFAULT_HOLD_SECONDS,
        live: false, confirmation: nil, resume: false,
        positions_service: nil, lifecycle: nil, observer: nil,
        logger: Rails.logger, sleeper: ->(s) { Kernel.sleep(s) }, clock: -> { Time.current })
        @product_id = product_id || ExecutionCalibration.default_product_id
        @round_trips = round_trips.to_i
        @hold_seconds = hold_seconds.to_i
        @live = live
        @confirmation = confirmation
        @resume = resume
        @logger = logger
        @sleeper = sleeper
        @clock = clock
        @positions_service = positions_service
        @lifecycle = lifecycle
        @observer = observer
        @tape = Tape.new(product_id: @product_id)
      end

      def call
        started = @clock.call
        refusals = gate_refusals
        return refused(refusals, started) if refusals.any?

        enter_execution_mode!
        # Preflight AFTER the mode is settled: the equity assertion and the
        # already-open check mean different things in paper and in live.
        preflight = Preflight.new(product_id: @product_id, logger: @logger)
        unless preflight.satisfied?
          preflight.refuse!
          return refused(preflight.failures, started)
        end

        journal = prepare_journal
        run_legs(journal)
      ensure
        @logger.info("[ExecutionCalibration] run finished for #{@product_id}")
      end

      private

      # ── Gates ──────────────────────────────────────────────────────────────

      def gate_refusals
        refusals = []
        if @product_id.blank?
          refusals << "no #{INSTRUMENT_PREFIX} contract is ingested — nothing to calibrate against. " \
                      "Sync products first (Contract::PREFIX_TO_BASE_CURRENCY already maps " \
                      "#{INSTRUMENT_PREFIX}), then re-run."
        elsif !@product_id.to_s.start_with?("#{INSTRUMENT_PREFIX}-")
          refusals << "instrument #{@product_id.inspect} is not a #{INSTRUMENT_PREFIX} contract — " \
                      "#486 authorizes #{INSTRUMENT_PREFIX} only"
        end
        refusals << "round_trips must be a positive even number, got #{@round_trips}" unless valid_round_trips?
        refusals.concat(live_gate_refusals) if @live
        refusals.concat(journal_refusals)
        refusals
      end

      def valid_round_trips? = @round_trips.positive? && @round_trips.even?

      # Three gates, deliberately independent: a flag someone typed, an
      # environment variable someone deployed, and a phrase someone had to read
      # this run's warning to know. No single mistake clears all three.
      def live_gate_refusals
        refusals = []
        if ENV["LIVE_TRADING_CONFIRMED"] != "1"
          refusals << "live requested but LIVE_TRADING_CONFIRMED is not \"1\" — the paper-default gate " \
                      "(Trading::ExecutionSafety) would force dry-run anyway; refusing rather than " \
                      "running a rehearsal an operator believes is live"
        end
        if @confirmation.to_s != CONFIRMATION_PHRASE
          refusals << "live requested but the typed confirmation did not match exactly: " \
                      "expected #{CONFIRMATION_PHRASE.inspect}"
        end
        refusals
      end

      def journal_refusals
        journal = Journal.load
        return [] unless journal.in_flight?
        return [] if @resume

        ["a calibration run (#{journal.run_id}) is already in flight with #{journal.completed_legs} leg(s) " \
         "recorded — resume it with --resume, or clear it deliberately. Starting fresh over an unfinished " \
         "run risks a position this harness does not know it opened."]
      end

      # ── Mode ───────────────────────────────────────────────────────────────

      def live? = @live && ENV["LIVE_TRADING_CONFIRMED"] == "1" && @confirmation.to_s == CONFIRMATION_PHRASE

      def enter_execution_mode!
        return if live?

        DryRun.enable!(logger: @logger) unless DryRun.active?
        @logger.warn("[ExecutionCalibration] DRY-RUN — orders are simulated. " \
                     "A dry run rehearses the mechanics; it cannot measure a real fee or a maker fill rate.")
      end

      def mode = live? ? :live : :dry_run

      # ── The run ────────────────────────────────────────────────────────────

      def prepare_journal
        journal = Journal.load
        return journal if @resume && journal.in_flight?

        Journal.start!(product_id: @product_id, round_trips: @round_trips)
      end

      def run_legs(journal)
        started = @clock.call
        first_leg = journal.completed_legs + 1
        @logger.info("[ExecutionCalibration] #{mode} run on #{@product_id}: legs #{first_leg}..#{@round_trips}")

        breach = nil
        (first_leg..@round_trips).each do |number|
          leg = execute_leg(number)
          @tape.add(leg)
          journal.record_leg!(leg)

          breach = AbortConditions.new(tape: @tape, logger: @logger).enforce!
          break if breach
        end

        journal.finish!(breach ? "aborted" : "completed")
        finalize(breach, started)
      end

      # One forced round trip. Sides alternate per PAIR so the taker leg and the
      # maker leg of a pair share a direction — otherwise the two arms are
      # compared across different market moves — and so 20 legs are 10 long and
      # 10 short, which nets the directional noise #486 budgets at ~$4.
      def execute_leg(number)
        intent = number.odd? ? :taker : :maker
        side = (((number - 1) / 2) % 2).zero? ? :long : :short
        intended_hold = @hold_seconds
        reference = RecentMarketPrice.for_product(@product_id)

        return failed_leg(number, intent, intended_hold, "no recent market price for #{@product_id}") unless reference

        result = place_entry(intent: intent, side: side, reference: reference)
        unless order_succeeded?(result)
          return failed_leg(number, intent, intended_hold, "order rejected: #{order_error(result)}")
        end

        entry = observer.observe(phase: :entry, side: side, intended_price: entry_intent_price(intent, reference, side),
          order_result: result, deadline: @clock.call + entry_deadline(intent))

        return unfilled_maker_leg(number, intent, intended_hold, result) if entry.nil?

        hold_and_close(number: number, intent: intent, side: side, entry: entry,
          intended_hold: intended_hold, order_result: result)
      end

      def place_entry(intent:, side:, reference:)
        type = (intent == :maker) ? :maker : :market
        price = (intent == :maker) ? Trading::CoinbasePositions.maker_price(reference, side) : nil

        positions_service.open_position(
          product_id: @product_id,
          side: side,
          size: 1,
          type: type,
          price: price,
          day_trading: true
        )
      rescue => e
        @logger.error("[ExecutionCalibration] entry raised: #{e.class}: #{e.message}")
        {"success" => false, "error" => "#{e.class}: #{e.message}"}
      end

      # Slippage is measured against what the order ASKED for: the market
      # reference for a taker entry, the posted limit for a maker entry.
      def entry_intent_price(intent, reference, side)
        (intent == :maker) ? Trading::CoinbasePositions.maker_price(reference, side) : reference
      end

      def entry_deadline(intent)
        (intent == :maker) ? Trading::CoinbasePositions.maker_ttl_seconds : TAKER_FILL_TIMEOUT_SECONDS
      end

      def hold_and_close(number:, intent:, side:, entry:, intended_hold:, order_result:)
        held_from = @clock.call
        @sleeper.call(intended_hold)

        position = resolve_position(order_result)
        unless position
          return failed_leg(number, intent, intended_hold,
            "entry filled but no Position record was found to close — refusing to continue with " \
            "untracked exposure", held_seconds: (@clock.call - held_from).to_f)
        end

        outcome = lifecycle.close(position, reason: "execution_calibration_leg_#{number}")
        held_seconds = (@clock.call - held_from).to_f

        unless outcome&.success?
          return failed_leg(number, intent, intended_hold,
            "close FAILED for position #{position.id} — exposure may remain on #{@product_id}; " \
            "flatten it by hand before doing anything else", held_seconds: held_seconds, position_id: position.id)
        end

        position.reload
        exit_fill = observe_exit(side: side, position: position, outcome: outcome)

        leg = Leg.new(number: number, intent: intent, entry: entry, exit: exit_fill,
          intended_hold_seconds: intended_hold, held_seconds: held_seconds,
          realized_pnl: position.pnl.to_f, position_id: position.id,
          funding_modeled: modeled_funding(position: position, side: side, outcome: outcome))

        return leg if flat?

        failed_leg(number, intent, intended_hold,
          "#{@product_id} is NOT flat after closing leg #{number} — refusing to open another position on top " \
          "of exposure this run cannot account for", held_seconds: held_seconds, position_id: position.id)
      end

      def observe_exit(side:, position:, outcome:)
        exit_side = (side == :long) ? :short : :long
        synthetic = {"success" => true, "price" => outcome.close_price, "fee" => position.exit_fee}
        observer.observe(phase: :exit, side: exit_side, intended_price: outcome.close_price,
          order_result: synthetic, deadline: @clock.call + TAKER_FILL_TIMEOUT_SECONDS)
      end

      # A maker entry that never rested into a fill is the observation #486
      # exists to collect, not an error. The exchange expires the order itself
      # (post-only GTD), so there is nothing to cancel — but the local Position
      # the acceptance created must be voided or it becomes a phantom.
      def unfilled_maker_leg(number, intent, intended_hold, order_result)
        void_unfilled_position(order_result)
        @logger.info("[ExecutionCalibration] leg #{number}: maker entry did not fill within " \
                     "#{Trading::CoinbasePositions.maker_ttl_seconds}s — recorded as an unfilled attempt")
        Leg.new(number: number, intent: intent, entry: nil, exit: nil,
          intended_hold_seconds: intended_hold, held_seconds: 0.0, realized_pnl: 0.0)
      end

      def void_unfilled_position(order_result)
        position = resolve_position(order_result)
        return unless position&.open?

        position.force_close!(position.entry_price, "execution_calibration_maker_entry_unfilled", Time.current, pnl: 0.0)
      end

      def failed_leg(number, intent, intended_hold, error, held_seconds: 0.0, position_id: nil)
        @logger.error("[ExecutionCalibration] leg #{number} failed: #{error}")
        Leg.new(number: number, intent: intent, entry: nil, exit: nil, error: error,
          intended_hold_seconds: intended_hold, held_seconds: held_seconds,
          realized_pnl: 0.0, position_id: position_id)
      end

      # The Position that THIS order created — CoinbasePositions#open_position
      # merges its id into the result (issue #480 lineage). Falling back to the
      # newest open row on the product would attribute someone else's position
      # to this run, which is exactly what the preflight refuses to allow.
      def resolve_position(order_result)
        id = order_result.is_a?(Hash) ? (order_result["position_id"] || order_result[:position_id]) : nil
        return Position.find_by(id: id) if id

        Position.open.by_product(@product_id).order(:entry_time).last
      end

      def flat?
        return false if Position.open.by_product(@product_id).exists?
        return true unless live?

        positions_service.list_open_positions(product_id: @product_id).empty?
      rescue => e
        @logger.error("[ExecutionCalibration] could not confirm flat on #{@product_id}: #{e.class}: #{e.message}")
        false
      end

      # Funding is a position-TIME cost. At a 30s hold almost no run will cross
      # a funding boundary, and the report says so rather than reporting $0.00
      # as though funding had been measured and found to be nothing.
      def modeled_funding(position:, side:, outcome:)
        rate = FundingRate.for_product(@product_id).chronological.last
        return 0.0 unless rate

        notional = position.entry_price.to_f * position.size.to_f *
          Trading::ContractSizeResolver.for_product(@product_id).to_f
        CostModel.funding_cost(notional: notional, side: side, entry_time: position.entry_time,
          exit_time: position.close_time || Time.current, rate: rate.funding_rate.to_f,
          interval: rate.funding_interval_seconds)
      rescue => e
        @logger.warn("[ExecutionCalibration] funding model unavailable: #{e.class}: #{e.message}")
        0.0
      end

      # ── Finishing ──────────────────────────────────────────────────────────

      def finalize(breach, started)
        persist_measured_fees
        report = Report.new(
          status: breach ? :aborted : :completed, mode: mode, product_id: @product_id,
          tape: @tape, breach: breach, refusals: [],
          reconciliation: reconciliation,
          maker_warning: AbortConditions.new(tape: @tape, logger: @logger).maker_fill_rate_warning,
          started_at: started, finished_at: @clock.call
        )
        @logger.info("[ExecutionCalibration] #{report.summary}")
        report
      end

      # Reuses the existing measured-fee path (issue #462) rather than writing
      # ProductFee rows here: FeeTruth is the measurement engine and
      # FeeMeasurementSnapshotJob is the only writer, so this run's commissions
      # reach CostModel by the same route as every other fill's.
      def persist_measured_fees
        FeeMeasurementSnapshotJob.perform_now
      rescue => e
        @logger.error("[ExecutionCalibration] fee snapshot failed: #{e.class}: #{e.message}")
      end

      # #376 gate 1 / #486 acceptance: measured rates reconciled against
      # CostModel within 10%, on the venue we intend to trade.
      def reconciliation
        modeled = CostModel.fee_for(@product_id)[:taker_rate].to_f
        measured = @tape.measured_taker_rate
        if measured.nil?
          return {measured_rate: nil, modeled_rate: modeled, within_tolerance: nil,
                  relative_drift: nil, note: "no taker fill produced a usable notional"}
        end

        drift = modeled.positive? ? (measured - modeled).abs / modeled : nil
        {measured_rate: measured, modeled_rate: modeled, relative_drift: drift,
         within_tolerance: drift.nil? ? nil : drift <= RECONCILIATION_TOLERANCE,
         tolerance: RECONCILIATION_TOLERANCE}
      end

      def refused(refusals, started)
        Array(refusals).each { |r| @logger.error("[ExecutionCalibration] REFUSED: #{r}") }
        Report.new(status: :refused, mode: nil, product_id: @product_id, tape: @tape,
          breach: nil, refusals: Array(refusals), reconciliation: nil,
          started_at: started, finished_at: @clock.call)
      end

      # ── Collaborators ──────────────────────────────────────────────────────

      def positions_service
        @positions_service ||= Trading::CoinbasePositions.new(logger: @logger)
      end

      def lifecycle
        @lifecycle ||= Trading::PositionLifecycle.new(positions_service: positions_service, logger: @logger)
      end

      def observer
        @observer ||= if live?
          FillObserver::Venue.new(positions_service: positions_service, multiplier: contract_multiplier,
            logger: @logger, sleeper: @sleeper)
        else
          FillObserver::Simulated.new(multiplier: contract_multiplier)
        end
      end

      def contract_multiplier
        value = Trading::ContractSizeResolver.for_product(@product_id).to_f
        value.positive? ? value : 1.0
      end

      def order_succeeded?(result)
        return false unless result.is_a?(Hash)

        !!(result["success"] || result[:success] || result["order_id"] || result[:order_id])
      end

      def order_error(result)
        return "unknown error" unless result.is_a?(Hash)

        result["error"] || result[:error] || "unknown error"
      end
    end
  end
end
