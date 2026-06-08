# frozen_string_literal: true

module RealtimeMonitoring
  class Session
    JOIN_TIMEOUT = 2

    def self.current
      @current ||= new
    end

    def self.reset_current!
      @current = nil
    end

    def initialize(logger: Rails.logger)
      @logger = logger
      @threads = []
      @futures_subscriber = nil
      @spot_subscriber = nil
      @futures_product_ids = []
      @spot_product_ids = []
      @started_at = nil
    end

    def active?
      @threads.any?(&:alive?)
    end

    def start!(product_ids: nil, futures_product_ids: nil, spot_product_ids: nil)
      return failure("Real-time monitoring already running") if active?

      explicit = Array(product_ids).compact
      @futures_product_ids = ProductResolver.futures_product_ids(override: futures_product_ids, explicit: explicit)
      @spot_product_ids = ProductResolver.spot_product_ids(override: spot_product_ids, explicit: explicit)

      if @futures_product_ids.empty? && @spot_product_ids.empty?
        return failure("No futures or spot products configured")
      end

      handler = TickHandler.new(logger: @logger)
      on_ticker = proc { |ticker_data| handler.process(ticker_data) }

      if @futures_product_ids.any?
        @futures_subscriber = MarketData::CoinbaseFuturesSubscriber.new(
          product_ids: @futures_product_ids,
          logger: @logger,
          on_ticker: on_ticker
        )
        @threads << Thread.new { @futures_subscriber.start }
      end

      if @spot_product_ids.any?
        @spot_subscriber = MarketData::CoinbaseSpotSubscriber.new(
          product_ids: @spot_product_ids,
          logger: @logger,
          on_ticker: on_ticker
        )
        @threads << Thread.new { @spot_subscriber.start }
      end

      @started_at = Time.current
      @logger.info(
        "[RTM] Started real-time monitoring for futures: #{@futures_product_ids.join(", ").presence || "none"}, " \
        "spot: #{@spot_product_ids.join(", ").presence || "none"}"
      )

      success("Real-time monitoring started")
    end

    def stop!
      return failure("Real-time monitoring is not running") unless active?

      @futures_subscriber&.stop
      @spot_subscriber&.stop
      @threads.each { |thread| thread.join(JOIN_TIMEOUT) }
      @threads.clear
      @futures_subscriber = nil
      @spot_subscriber = nil
      @started_at = nil
      @futures_product_ids = []
      @spot_product_ids = []

      @logger.info("[RTM] Stopped real-time monitoring")
      success("Real-time monitoring stopped")
    end

    def toggle!
      active? ? stop! : start!
    end

    def run_blocking(**kwargs)
      result = start!(**kwargs)
      return result unless result[:success]

      @threads.each(&:join)
      result
    end

    def status
      {
        active: active?,
        started_at: @started_at,
        futures_product_ids: @futures_product_ids,
        spot_product_ids: @spot_product_ids,
        good_job_pending: pending_good_job_count
      }
    end

    private

    def pending_good_job_count
      return 0 unless defined?(GoodJob::Job)

      GoodJob::Job.where(job_class: "RealTimeMonitoringJob", finished_at: nil).count
    rescue
      0
    end

    def success(message)
      {success: true, message: message}
    end

    def failure(message)
      {success: false, error: message}
    end
  end
end
