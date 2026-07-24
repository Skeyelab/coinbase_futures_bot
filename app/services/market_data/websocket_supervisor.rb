# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  # Keeps a single WebSocket connection alive, reconnecting when it dies (issue:
  # market-data feed silently stopped when a socket dropped with no reconnect).
  # Owns the connection lifecycle only; callers supply the subscribe/parse logic
  # via on_open/on_message.
  class WebsocketSupervisor
    DEFAULT_CONNECT = ->(url) { WebSocket::Client::Simple.connect(url) }
    DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    DEFAULT_SLEEPER = ->(seconds) { Kernel.sleep(seconds) }

    # sleeper is the loop's only blocking point; tests drive the loop through it.
    attr_accessor :sleeper

    def initialize(url:, on_message:, on_open: nil, on_close: nil, on_error: nil,
      logger: Rails.logger, stale_after: 60.0, poll_interval: 0.1,
      backoff_base: 1.0, backoff_cap: 30.0,
      connect: DEFAULT_CONNECT, clock: DEFAULT_CLOCK, sleeper: DEFAULT_SLEEPER)
      @url = url
      @on_message = on_message
      @on_open = on_open
      @on_close = on_close
      @on_error = on_error
      @logger = logger
      @stale_after = stale_after.to_f
      @poll_interval = poll_interval
      @backoff_base = backoff_base.to_f
      @backoff_cap = backoff_cap.to_f
      @connect = connect
      @clock = clock
      @sleeper = sleeper
      @stopped = false
    end

    # Blocks, supervising the connection until #stop is called.
    def run
      @attempt = 0
      until @stopped
        healthy = false
        begin
          open_connection
          supervise
          healthy = @got_message
        rescue => e
          # A failed connect (or a raise while supervising) is a dead attempt,
          # not a fatal error — report it and retry with backoff.
          @logger&.warn("[MD] websocket connection error: #{e.class}: #{e.message}")
          @on_error&.call(e)
        ensure
          teardown
        end
        break if @stopped

        # A connection that carried data resets the backoff: a rare drop on an
        # otherwise-healthy feed should reconnect immediately, not inherit a long
        # delay from an earlier outage.
        @attempt = healthy ? 0 : @attempt + 1
        wait = backoff_seconds(@attempt)
        @sleeper.call(wait) if wait.positive?
      end
    end

    # Exponential backoff, capped, so a persistent outage does not hammer the
    # exchange.
    def backoff_seconds(attempt)
      return 0.0 if attempt <= 0

      [@backoff_base * (2**(attempt - 1)), @backoff_cap].min
    end

    def stop
      @stopped = true
    end

    private

    def open_connection
      @closed = false
      @got_message = false
      @socket = @connect.call(@url)
      @last_activity = @clock.call
      wire(@socket)
    end

    # WebSocket::Client::Simple invokes handler blocks via instance_exec (self ==
    # the socket), so capture the supervisor in a local and dispatch through it.
    def wire(socket)
      sup = self
      socket.on(:open) { sup.__send__(:handle_open) }
      socket.on(:message) { |msg| sup.__send__(:handle_message, msg) }
      socket.on(:close) { sup.__send__(:handle_close) }
      socket.on(:error) { |e| sup.__send__(:handle_error, e) }
    end

    def supervise
      loop do
        return if @stopped
        return if @closed
        return if stale?

        @sleeper.call(@poll_interval)
      end
    end

    # A live Coinbase ticker streams constantly, so silence past @stale_after is
    # a dead (often half-open) socket the :close event never reported.
    def stale?
      (@clock.call - @last_activity) > @stale_after
    end

    def handle_open
      @on_open&.call(@socket)
    end

    def handle_message(message)
      @last_activity = @clock.call
      @got_message = true
      @on_message.call(message)
    end

    def handle_close
      @closed = true
      @on_close&.call
    end

    def handle_error(error)
      @on_error&.call(error)
    end

    def teardown
      @socket&.close
    rescue
      nil
    ensure
      @socket = nil
    end
  end
end
