# frozen_string_literal: true

module Trading
  # Whether calibration may change what the live strategy reads (issue #483).
  #
  # CalibrationJob runs nightly at 02:00 UTC and calls TradingProfile#activate!,
  # mutating the per-symbol tp/sl/risk that the live path reads through
  # TradingProfile.effective. #376 gate 2 requires a sample gathered under a
  # FROZEN config — so the config was being silently unfrozen every night, and
  # no sample accumulated so far is gate-eligible.
  #
  # That clause is not bureaucratic. With a grid of G candidates and the gate
  # applied to the winner, the false-positive rate under a true edge of zero is
  # 1 - 0.975^G: a 20-cell grid green-lights a dead strategy ~40% of the time.
  # Freezing BEFORE the evidence window is the only thing standing against that.
  #
  # Freezing suspends ACTIVATION, not calibration. The search keeps running and
  # keeps recording proposals, so nothing is lost and the winner is available
  # the moment the window closes — it simply stops rewriting live config
  # mid-sample.
  #
  # Durable in bot_runtime_stats, like TradingHalt and DryRun, so every process
  # sees the same state and a restart cannot silently unfreeze.
  module CalibrationFreeze
    STORE_KEY = "calibration_freeze"

    module_function

    def frozen?
      record = BotRuntimeStat.find_by(key: STORE_KEY)
      !!(record&.value || {})["frozen"]
    end

    def freeze!(reason: nil, logger: Rails.logger)
      write(frozen: true, reason: reason.to_s.presence)
      logger.warn("[CalibrationFreeze] FROZEN — calibration will not activate profiles" \
                  "#{": #{reason}" if reason.present?}")
      status
    end

    def unfreeze!(logger: Rails.logger)
      write(frozen: false, reason: nil)
      logger.warn("[CalibrationFreeze] unfrozen — calibration may activate profiles again")
      status
    end

    def reason
      record = BotRuntimeStat.find_by(key: STORE_KEY)
      (record&.value || {})["reason"].presence
    end

    def status
      {frozen: frozen?, reason: reason, as_of: Time.current.utc.iso8601}
    end

    def write(frozen:, reason:)
      record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
      record.value = {"frozen" => frozen, "reason" => reason}
      record.recorded_at = Time.current.utc
      record.save!
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
