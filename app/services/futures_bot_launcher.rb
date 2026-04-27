# frozen_string_literal: true

# FuturesBotLauncher coordinates the three subsystems that make up a full bot
# session: market-data subscribers, the realtime signal runner, and the TUI
# dashboard.
#
# Usage (from CLI):
#   launcher = FuturesBotLauncher.new
#   launcher.start   # blocks until TUI exits, then shuts down background threads
#
# The caller owns the TUI instance so it can inject a custom one in tests.
class FuturesBotLauncher
  attr_reader :spot_thread, :futures_thread, :signal_thread

  def initialize(
    logger: Rails.logger,
    tui: nil,
    tui_refresh: Cli::TuiDashboard::DEFAULT_REFRESH,
    signal_interval: ENV.fetch("REALTIME_SIGNAL_EVALUATION_INTERVAL", "30").to_i,
    skip_market_data: ENV["FUTURESBOT_SKIP_MARKET_DATA"].present?,
    skip_signal_runner: ENV["FUTURESBOT_SKIP_SIGNAL_RUNNER"].present?
  )
    @logger = logger
    @tui = tui || Cli::TuiDashboard.new(refresh_interval: tui_refresh)
    @signal_interval = signal_interval
    @skip_market_data = skip_market_data
    @skip_signal_runner = skip_signal_runner
    @spot_thread = nil
    @futures_thread = nil
    @signal_thread = nil
  end

  # Start all subsystems, launch the TUI in the foreground, then shut down.
  def start
    @logger.info("[Launcher] Starting FuturesBot...")

    start_market_data unless @skip_market_data
    start_signal_runner unless @skip_signal_runner

    @logger.info("[Launcher] Launching TUI dashboard...")
    @tui.start
  ensure
    shutdown
  end

  # Shut down background threads gracefully.
  def shutdown
    @logger.info("[Launcher] Shutting down background threads...")
    [@spot_thread, @futures_thread, @signal_thread].each do |t|
      t&.kill if t&.alive?
    end
    @logger.info("[Launcher] Shutdown complete.")
  end

  private

  def start_market_data
    product_ids = TradingPair.enabled.pluck(:product_id)

    if product_ids.empty?
      @logger.warn("[Launcher] No enabled trading pairs found – skipping market data subscription.")
      return
    end

    @logger.info("[Launcher] Starting market data subscriptions for: #{product_ids.join(", ")}")
    on_ticker = build_tick_persister

    @spot_thread = Thread.new do
      @logger.info("[Launcher] Spot subscriber starting...")
      MarketData::CoinbaseSpotSubscriber.new(
        product_ids: product_ids,
        enable_candle_aggregation: true,
        logger: @logger,
        on_ticker: on_ticker
      ).start
    rescue => e
      @logger.error("[Launcher] Spot subscriber error: #{e.class}: #{e.message}")
    end

    @futures_thread = Thread.new do
      @logger.info("[Launcher] Futures subscriber starting...")
      MarketData::CoinbaseFuturesSubscriber.new(
        product_ids: product_ids,
        enable_candle_aggregation: true,
        logger: @logger,
        on_ticker: on_ticker
      ).start
    rescue => e
      @logger.error("[Launcher] Futures subscriber error: #{e.class}: #{e.message}")
    end
  end

  def start_signal_runner
    runner = RealtimeSignalRunner.new(
      job_class: RealTimeSignalJob,
      logger: @logger,
      interval_seconds: @signal_interval
    )

    @signal_thread = Thread.new do
      @logger.info("[Launcher] Signal runner starting (interval=#{@signal_interval}s)...")
      runner.start!
      loop do
        sleep 1
        runner.tick(now: Time.current.utc)
      end
    rescue => e
      @logger.error("[Launcher] Signal runner error: #{e.class}: #{e.message}")
    end
  end

  def build_tick_persister
    lambda do |tick|
      product_id = tick["product_id"].presence
      price = tick["price"]&.to_d
      observed_at = begin
        Time.parse(tick["time"].to_s).utc
      rescue
        Time.current.utc
      end
      next if product_id.blank? || price.nil?

      Tick.create!(product_id: product_id, price: price, observed_at: observed_at)
    rescue => e
      @logger.error("[Launcher] Failed to persist tick: #{e.class}: #{e.message}")
    end
  end
end
