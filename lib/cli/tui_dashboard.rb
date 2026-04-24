# frozen_string_literal: true

require "io/console"

# TuiDashboard renders a full-screen, auto-refreshing terminal dashboard
# for the Coinbase Futures Bot.  It uses ANSI escape codes and the Ruby
# io/console stdlib extension (zero extra gems).
#
# Key bindings (no Enter needed):
#   q / Q / Ctrl+C / Escape  – quit
#   r / R                    – force immediate refresh
#   p / P                    – toggle positions section
#   s / S                    – toggle signals section
#   +                        – refresh faster (decrease interval by 1 s, min 1 s)
#   -                        – refresh slower (increase interval by 1 s)
class TuiDashboard
  DEFAULT_REFRESH = 5 # seconds

  # ANSI escape helpers
  RESET = "\e[0m"
  BOLD = "\e[1m"
  DIM = "\e[2m"
  RED = "\e[31m"
  GREEN = "\e[32m"
  YELLOW = "\e[33m"
  CYAN = "\e[36m"
  CLEAR_SCREEN = "\e[2J"
  CURSOR_HOME = "\e[H"
  CLEAR_EOL = "\e[K"
  CLEAR_EOS = "\e[J" # clear from cursor to end of screen
  HIDE_CURSOR = "\e[?25l"
  SHOW_CURSOR = "\e[?25h"

  # Key → action mapping
  KEY_ACTIONS = {
    "q" => :quit, "Q" => :quit, "\e" => :quit, "\x03" => :quit,
    "r" => :force_refresh, "R" => :force_refresh,
    "p" => :toggle_positions, "P" => :toggle_positions,
    "s" => :toggle_signals, "S" => :toggle_signals,
    "+" => :faster, "=" => :faster,
    "-" => :slower
  }.freeze

  attr_reader :running, :show_positions, :show_signals, :refresh_interval

  def initialize(refresh_interval: DEFAULT_REFRESH, output: $stdout)
    @refresh_interval = refresh_interval
    @output = output
    @running = true
    @show_positions = true
    @show_signals = true
    @data = {}
    @error = nil
    # Trigger an immediate render on first loop iteration
    @last_refresh = Time.now - refresh_interval
  end

  # Public entry point – call this to launch the dashboard.
  def start
    if @output.tty?
      run_interactive
    else
      # Non-TTY (piped / test): render once and return
      refresh_data
      render
    end
  end

  # Process a single keypress.  Public so specs can drive it directly.
  def handle_keypress(key)
    action = KEY_ACTIONS[key]
    return unless action

    case action
    when :quit
      @running = false
    when :force_refresh
      @last_refresh = Time.now - @refresh_interval
    when :toggle_positions
      @show_positions = !@show_positions
      @last_refresh = Time.now - @refresh_interval
    when :toggle_signals
      @show_signals = !@show_signals
      @last_refresh = Time.now - @refresh_interval
    when :faster
      @refresh_interval = [@refresh_interval - 1, 1].max
      @last_refresh = Time.now - @refresh_interval
    when :slower
      @refresh_interval += 1
    end
  end

  # Fetch live data from the database.  Public so specs can call it.
  def refresh_data
    @data = {
      day_pos_count: Position.open.day_trading.count,
      swing_pos_count: Position.open.swing_trading.count,
      signal_count: SignalAlert.active.count,
      session_count: ChatSession.active.count,
      positions: Position.open.order(entry_time: :desc).limit(15).to_a,
      signals: SignalAlert.active.recent.order(alert_timestamp: :desc).limit(10).to_a,
      refreshed_at: Time.now
    }
    @error = nil
  rescue => e
    @error = e.message
  end

  # Render the dashboard to @output.  Public so specs can assert on output.
  def render
    cols = terminal_cols
    buf = +"" # mutable string

    buf << CURSOR_HOME

    # ── Header ────────────────────────────────────────────────────────────────
    ts = @data[:refreshed_at]&.strftime("%H:%M:%S") || "--:--:--"
    divider_heavy = "#{DIM}#{"═" * cols}#{RESET}"
    buf << divider_heavy << "\n"
    buf << "  #{BOLD}#{CYAN}🤖  FuturesBot#{RESET}  " \
           "#{DIM}#{ts}  ·  #{RESET}" \
           "[q]uit  [r]efresh  [p]ositions  [s]ignals  [+/-] speed" \
           "#{CLEAR_EOL}\n"
    buf << divider_heavy << "\n"

    # ── Status row ────────────────────────────────────────────────────────────
    d = @data
    buf << "  #{BOLD}Status#{RESET}" \
           "  ·  Day: #{colorize(d[:day_pos_count] || 0)}" \
           "  #{DIM}·#{RESET}  Swing: #{colorize(d[:swing_pos_count] || 0)}" \
           "  #{DIM}·#{RESET}  Signals: #{colorize(d[:signal_count] || 0)}" \
           "  #{DIM}·#{RESET}  Sessions: #{d[:session_count] || 0}" \
           "#{CLEAR_EOL}\n"

    # ── Positions section ─────────────────────────────────────────────────────
    if @show_positions
      positions = d[:positions] || []
      buf << divider_light(cols)
      buf << "  #{BOLD}#{CYAN}Open Positions#{RESET}  #{DIM}(#{positions.size})#{RESET}#{CLEAR_EOL}\n"

      if positions.any?
        buf << "#{CLEAR_EOL}\n"
        buf << "  #{BOLD}#{format("%-6s  %-22s  %-6s  %-11s  %-8s  %-6s",
          "ID", "Product", "Side", "Entry", "Size", "Type")}#{RESET}#{CLEAR_EOL}\n"
        buf << "  #{DIM}#{"─" * [cols - 4, 64].min}#{RESET}#{CLEAR_EOL}\n"

        positions.each do |pos|
          sc = pos.long? ? GREEN : RED
          buf << format("  %-6s  %-22s  ", pos.id, pos.product_id.to_s[0, 22])
          buf << "#{sc}#{format("%-6s", pos.side)}#{RESET}"
          buf << format("  %-11s  %-8s  %-6s",
            pos.entry_price&.round(2) || "N/A",
            pos.size.to_s[0, 8],
            pos.day_trading? ? "Day" : "Swing")
          buf << "#{CLEAR_EOL}\n"
        end
      else
        buf << "  #{YELLOW}No open positions#{RESET}#{CLEAR_EOL}\n"
      end
    end

    # ── Signals section ───────────────────────────────────────────────────────
    if @show_signals
      signals = d[:signals] || []
      buf << divider_light(cols)
      buf << "  #{BOLD}#{CYAN}Active Signals#{RESET}  #{DIM}(#{signals.size})#{RESET}#{CLEAR_EOL}\n"

      if signals.any?
        buf << "#{CLEAR_EOL}\n"
        buf << "  #{BOLD}#{format("%-6s  %-16s  %-6s  %-9s  %-6s  %-20s",
          "ID", "Symbol", "Side", "Type", "Conf%", "Strategy")}#{RESET}#{CLEAR_EOL}\n"
        buf << "  #{DIM}#{"─" * [cols - 4, 70].min}#{RESET}#{CLEAR_EOL}\n"

        signals.each do |sig|
          sc = sig.long? ? GREEN : RED
          cc = sig.confidence >= 80 ? GREEN : (sig.confidence >= 60 ? YELLOW : RED)
          buf << format("  %-6s  %-16s  ", sig.id, sig.symbol.to_s[0, 16])
          buf << "#{sc}#{format("%-6s", sig.side)}#{RESET}"
          buf << format("  %-9s  ", sig.signal_type)
          buf << "#{cc}#{format("%-6s", sig.confidence.to_i)}#{RESET}"
          buf << format("  %-20s", sig.strategy_name.to_s[0, 20])
          buf << "#{CLEAR_EOL}\n"
        end
      else
        buf << "  #{YELLOW}No active signals#{RESET}#{CLEAR_EOL}\n"
      end
    end

    # ── Error section ─────────────────────────────────────────────────────────
    if @error
      buf << divider_light(cols)
      buf << "  #{RED}#{BOLD}Error:#{RESET}  #{RED}#{@error.to_s[0, cols - 12]}#{RESET}#{CLEAR_EOL}\n"
    end

    # ── Footer ────────────────────────────────────────────────────────────────
    buf << divider_heavy << "\n"
    elapsed = Time.now - (@last_refresh || Time.now)
    next_in = [@refresh_interval - elapsed, 0].max.ceil
    buf << "  #{DIM}Last: #{@data[:refreshed_at]&.strftime("%H:%M:%S") || "never"}" \
           "  ·  Next in: #{next_in}s  ·  Interval: #{@refresh_interval}s#{RESET}" \
           "#{CLEAR_EOL}\n"
    buf << divider_heavy << "\n"

    # Clear any leftover lines from a taller previous render
    buf << CLEAR_EOS

    @output.print(buf)
    @output.flush
  end

  private

  # ── Interactive loop ─────────────────────────────────────────────────────────

  def run_interactive
    setup_terminal

    loop do
      # Non-blocking keypress poll (50 ms timeout)
      if IO.select([$stdin], nil, nil, 0.05)
        key = begin
          $stdin.read_nonblock(1)
        rescue
          nil
        end
        handle_keypress(key)
      end

      break unless @running

      if (Time.now - @last_refresh) >= @refresh_interval
        refresh_data
        render
        @last_refresh = Time.now
      end
    end
  ensure
    restore_terminal
    @output.puts "\nFuturesBot Dashboard closed."
  end

  # ── Terminal setup / teardown ─────────────────────────────────────────────────

  def setup_terminal
    @saved_tty = `stty -g 2>/dev/null`.chomp
    begin
      $stdin.raw!
      $stdin.echo = false
    rescue
      # Non-TTY environment – raw mode not available, skip
    end
    @output.print(HIDE_CURSOR + CLEAR_SCREEN)
    Signal.trap("INT") { @running = false }
    Signal.trap("TERM") { @running = false }
    # Re-render immediately when the terminal is resized
    Signal.trap("WINCH") { @last_refresh = Time.now - @refresh_interval }
  end

  def restore_terminal
    if @saved_tty && !@saved_tty.empty?
      system("stty #{@saved_tty}")
    end
    begin
      $stdin.cooked!
      $stdin.echo = true
    rescue
      # Non-TTY environment – skip restore
    end
    @output.print(SHOW_CURSOR)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  def divider_light(cols)
    "#{DIM}#{"─" * cols}#{RESET}#{CLEAR_EOL}\n"
  end

  def terminal_cols
    IO.console&.winsize&.last&.to_i || 80
  rescue
    80
  end

  def colorize(count)
    count > 0 ? "#{GREEN}#{BOLD}#{count}#{RESET}" : "#{DIM}#{count}#{RESET}"
  end
end
