# frozen_string_literal: true

module Trading
  module ExecutionCalibration
    # Durable progress for one calibration run, in bot_runtime_stats (the same
    # cross-process pattern as TradingHalt / DryRun / SymbolSuspension).
    #
    # Exists so a crash between leg 7's entry and leg 7's exit cannot become an
    # untracked open position: the run's state is on disk before the next order
    # is placed, so a restart knows a run was in flight, refuses to start a
    # fresh one over it, and can resume at the leg it stopped on rather than
    # re-running the whole 20 and paying for them twice.
    class Journal
      STORE_KEY = "execution_calibration_run"

      attr_reader :record

      def self.load = new(BotRuntimeStat.find_or_initialize_by(key: STORE_KEY))

      def self.start!(product_id:, round_trips:, run_id: SecureRandom.uuid)
        load.tap { |j| j.start!(product_id: product_id, round_trips: round_trips, run_id: run_id) }
      end

      def self.clear!
        BotRuntimeStat.find_by(key: STORE_KEY)&.destroy
      end

      def initialize(record)
        @record = record
      end

      def value = (record.value || {}).to_h

      def status = value["status"]

      def run_id = value["run_id"]

      def product_id = value["product_id"]

      def in_flight? = status == "running"

      def completed_legs = Array(value["legs"]).size

      def legs = Array(value["legs"])

      def start!(product_id:, round_trips:, run_id: SecureRandom.uuid)
        write(
          "run_id" => run_id,
          "product_id" => product_id,
          "round_trips" => round_trips,
          "status" => "running",
          "started_at" => Time.current.utc.iso8601,
          "legs" => []
        )
        self
      end

      # Written AFTER the leg is flat, so a leg present here is a leg that is
      # known to be closed.
      def record_leg!(leg)
        entries = Array(value["legs"])
        entries << {
          "number" => leg.number,
          "intent" => leg.intent.to_s,
          "entry_filled" => leg.entry_filled?,
          "realized_pnl" => leg.realized_pnl.to_f,
          "error" => leg.error,
          "at" => Time.current.utc.iso8601
        }
        write(value.merge("legs" => entries))
        self
      end

      def finish!(status)
        write(value.merge("status" => status.to_s, "finished_at" => Time.current.utc.iso8601))
        self
      end

      private

      def write(hash)
        record.value = hash
        record.recorded_at = Time.current.utc
        record.save!
        @record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
      rescue ActiveRecord::RecordNotUnique
        @record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
        retry
      end
    end
  end
end
