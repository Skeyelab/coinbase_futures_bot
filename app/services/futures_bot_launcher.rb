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
  THREAD_SHUTDOWN_TIMEOUT = 1
  attr_reader :spot_thread, :futures_thread, :signal_thread, :sentiment_thread

  def initialize(
    logger: Rails.logger,
    tui: nil,
    tui_refresh: nil,
    signal_interval: ENV.fetch("REALTIME_SIGNAL_EVALUATION_INTERVAL", "30").to_i,
    sentiment_interval: ENV.fetch("SENTIMENT_PIPELINE_INTERVAL_SECONDS", "120").to_i,
    skip_market_data: ENV["FUTURESBOT_SKIP_MARKET_DATA"].present?,
    skip_signal_runner: ENV["FUTURESBOT_SKIP_SIGNAL_RUNNER"].present?,
    skip_sentiment_pipeline: ENV["FUTURESBOT_SKIP_SENTIMENT_PIPELINE"].present?
  )
    @logger = logger
    @tui = tui || :bubbletea
    @tui_refresh = tui_refresh
    @signal_interval = signal_interval
    @sentiment_interval = sentiment_interval
    @skip_market_data = skip_market_data
    @skip_signal_runner = skip_signal_runner
    @skip_sentiment_pipeline = skip_sentiment_pipeline
    @spot_thread = nil
    @futures_thread = nil
    @signal_thread = nil
    @sentiment_thread = nil
    @spot_subscriber = nil
    @futures_subscriber = nil
    @shutdown_requested = false
  end

  # Start all subsystems, launch the TUI in the foreground, then shut down.
  def start
    @shutdown_requested = false
    @logger.info("[Launcher] Starting FuturesBot...")

    enforce_execution_safety

    start_market_data unless @skip_market_data
    start_signal_runner unless @skip_signal_runner
    start_sentiment_pipeline unless @skip_sentiment_pipeline

    @logger.info("[Launcher] Launching TUI dashboard...")
    if @tui == :bubbletea
      require "tui"
      Bubbletea.run(Tui::App.new, alt_screen: true)
    else
      @tui.start
    end
  ensure
    shutdown
  end

  # Shut down background threads gracefully.
  def shutdown
    @logger.info("[Launcher] Shutting down background threads...")
    @shutdown_requested = true
    @spot_subscriber&.stop
    @futures_subscriber&.stop

    stop_thread(@spot_thread, label: "spot subscriber")
    stop_thread(@futures_thread, label: "futures subscriber")
    stop_thread(@signal_thread, label: "signal runner")
    stop_thread(@sentiment_thread, label: "sentiment pipeline")

    @logger.info("[Launcher] Shutdown complete.")
  end

  private

  # Fail-safe execution default: a fresh or unconfigured launch must never send
  # real orders to Coinbase. Live trading is opt-in only — the operator must set
  # LIVE_TRADING_CONFIRMED=1 *and* have dry-run disabled. Absent that explicit
  # confirmation, force DRY-RUN before any subsystem (and thus any order flow)
  # starts, so "start the bot" defaults to paper. See DryRun.
  def enforce_execution_safety
    return if ENV["LIVE_TRADING_CONFIRMED"] == "1"
    return if DryRun.active?

    @logger.warn("[Launcher] Live trading not confirmed — forcing DRY-RUN. " \
                 "Set LIVE_TRADING_CONFIRMED=1 and disable dry-run to trade live.")
    DryRun.enable!(logger: @logger)
  end

  def start_market_data
    futures_product_ids = MarketData::RealtimeSubscriptionCatalog.futures_product_ids
    spot_product_ids = MarketData::RealtimeSubscriptionCatalog.spot_product_ids

    if futures_product_ids.empty? && spot_product_ids.empty?
      @logger.warn("[Launcher] No enabled trading pairs found – skipping market data subscription.")
      return
    end

    on_ticker = build_tick_persister

    if spot_product_ids.any?
      @logger.info("[Launcher] Starting spot market data subscriptions for: #{spot_product_ids.join(", ")}")
      @spot_subscriber = MarketData::CoinbaseSpotSubscriber.new(
        product_ids: spot_product_ids,
        enable_candle_aggregation: true,
        logger: @logger,
        on_ticker: on_ticker
      )

      @spot_thread = Thread.new do
        @logger.info("[Launcher] Spot subscriber starting...")
        @spot_subscriber.start
      rescue => e
        @logger.error("[Launcher] Spot subscriber error: #{e.class}: #{e.message}")
      end
    else
      @logger.info("[Launcher] No spot product ids resolved from enabled trading pairs.")
    end

    @logger.info("[Launcher] Starting futures market data subscriptions for: #{futures_product_ids.join(", ")}")
    @futures_subscriber = MarketData::CoinbaseFuturesSubscriber.new(
      product_ids: futures_product_ids,
      enable_candle_aggregation: true,
      logger: @logger,
      on_ticker: on_ticker
    )

    @futures_thread = Thread.new do
      @logger.info("[Launcher] Futures subscriber starting...")
      @futures_subscriber.start
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
        break if @shutdown_requested

        runner.tick(now: Time.current.utc)
      end
    rescue => e
      @logger.error("[Launcher] Signal runner error: #{e.class}: #{e.message}")
    end
  end

  def start_sentiment_pipeline
    runner = Sentiment::PipelineRunner.new(
      logger: @logger,
      interval_seconds: @sentiment_interval
    )

    @sentiment_thread = Thread.new do
      @logger.info("[Launcher] Sentiment pipeline starting (interval=#{@sentiment_interval}s)...")
      runner.start!
      loop do
        sleep 1
        break if @shutdown_requested

        runner.tick(now: Time.current.utc)
      end
    rescue => e
      @logger.error("[Launcher] Sentiment pipeline error: #{e.class}: #{e.message}")
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

  def stop_thread(thread, label:)
    return unless thread

    thread.join(THREAD_SHUTDOWN_TIMEOUT)
    return unless thread.alive?

    @logger.warn("[Launcher] #{label} did not stop cleanly; killing thread.")
    thread.kill
    thread.join(THREAD_SHUTDOWN_TIMEOUT)
  end
end
