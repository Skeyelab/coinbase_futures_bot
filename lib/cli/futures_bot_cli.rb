# frozen_string_literal: true

require "thor"
require_relative "../tui"

# Cli::FuturesBotCli provides a Thor-based command-line interface for
# interacting with the Coinbase Futures Bot from the shell.
#
# Usage:
#   bin/futuresbot start            # Launch all-in-one: TUI + market data + signals
#   bin/futuresbot dashboard         # Real-time full-screen TUI dashboard
#   bin/futuresbot status            # Show system status
#   bin/futuresbot positions         # List open positions
#   bin/futuresbot signals           # List active signals
#   bin/futuresbot help              # Show help
module Cli
  class FuturesBotCli < Thor
    # ─── Colours ────────────────────────────────────────────────────────────────
    RESET = "\e[0m"
    BOLD = "\e[1m"
    RED = "\e[31m"
    GREEN = "\e[32m"
    YELLOW = "\e[33m"
    CYAN = "\e[36m"
    WHITE = "\e[37m"

    # Tell Thor to exit with a non-zero status code when a command fails.
    def self.exit_on_failure?
      true
    end

    # Run the TUI dashboard when no subcommand is given.
    default_command :dashboard

    # ─── dashboard ──────────────────────────────────────────────────────────────
    desc "dashboard", "Launch the real-time full-screen TUI dashboard (keys: [i]mport, [c]lose, [o]reconcile)"
    def dashboard
      sync_startup_positions
      at_exit { RealtimeMonitoring::Session.current.stop! }
      Bubbletea.run(Tui::App.new, alt_screen: true)
    end

    # ─── status ─────────────────────────────────────────────────────────────────
    desc "status", "Show the current bot and system status"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def status
      return emit_json(OperatorSnapshot.new.status) if json_mode?

      day_pos = Position.open.day_trading.count
      swing_pos = Position.open.swing_trading.count
      signals = SignalAlert.active.count
      sessions = ChatSession.active.count

      puts "#{BOLD}#{CYAN}📊  FuturesBot Status#{RESET}"
      puts "─" * 40
      puts "  #{YELLOW}#{BOLD}🧪 DRY-RUN — simulated orders, nothing sent to Coinbase#{RESET}" if DryRun.active?
      puts "  #{WHITE}Day-trading positions:  #{RESET}#{colorize_count(day_pos)}"
      puts "  #{WHITE}Swing positions:        #{RESET}#{colorize_count(swing_pos)}"
      puts "  #{WHITE}Active signals:         #{RESET}#{colorize_count(signals)}"
      puts "  #{WHITE}Chat sessions:          #{RESET}#{sessions}"
      puts "  #{WHITE}Realtime loop:          #{RESET}#{format_liveness("realtime_signal")}"
      puts "  #{WHITE}Market data:            #{RESET}#{format_liveness("market_data")}"
      puts "─" * 40
      print_paper_section
      print_sentiment_section
      print_indicators_section
      puts "─" * 40
      puts "  #{WHITE}Status:#{RESET} #{GREEN}#{BOLD}operational#{RESET}"
    end

    # ─── positions ──────────────────────────────────────────────────────────────
    desc "positions", "List all open trading positions"
    method_option :type, aliases: "-t", type: :string,
      desc: "Filter by type: day | swing"
    method_option :limit, aliases: "-n", type: :numeric, default: 20,
      desc: "Maximum number of positions to display"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def positions
      snapshot = OperatorSnapshot.new.positions
      return emit_json(snapshot) if json_mode?

      rows = snapshot[:positions]
      rows = rows.select { |r| r[:day_trading] } if options[:type] == "day"
      rows = rows.reject { |r| r[:day_trading] } if options[:type] == "swing"
      rows = rows.first(options[:limit])

      puts "#{BOLD}#{CYAN}📈  Open Positions#{RESET} (#{rows.size})"
      puts "─" * 72

      if rows.empty?
        puts "  #{YELLOW}No open positions found.#{RESET}"
      else
        puts format_positions_header
        rows.each { |p| puts format_position_row(p) }
      end

      puts "─" * 72
    end

    # ─── signals ────────────────────────────────────────────────────────────────
    desc "signals", "List recent active trading signals"
    method_option :limit, aliases: "-n", type: :numeric, default: 10,
      desc: "Maximum number of signals to display"
    method_option :min_confidence, aliases: "-c", type: :numeric, default: 0,
      desc: "Minimum confidence threshold (0-100)"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def signals
      return emit_json(OperatorSnapshot.new.signals) if json_mode?

      scope = SignalAlert.active.recent
      scope = scope.high_confidence(options[:min_confidence]) if options[:min_confidence] > 0
      rows = scope.order(alert_timestamp: :desc).limit(options[:limit]).to_a

      puts "#{BOLD}#{CYAN}🔔  Active Signals#{RESET} (#{rows.size})"
      puts "─" * 72

      if rows.empty?
        puts "  #{YELLOW}No active signals found.#{RESET}"
      else
        puts format_signals_header
        rows.each { |s| puts format_signal_row(s) }
      end

      puts "─" * 72
    end

    # ─── start ──────────────────────────────────────────────────────────────────
    desc "start", "Launch TUI dashboard + market data feed + signal evaluation in one command"
    method_option :refresh, aliases: "-r", type: :numeric, default: 5,
      desc: "TUI auto-refresh interval in seconds"
    def start
      sync_startup_positions
      FuturesBotLauncher.new(tui_refresh: options[:refresh]).start
    end

    # ─── halt ───────────────────────────────────────────────────────────────────
    desc "halt", "Halt all trading immediately (kill switch)"
    method_option :reason, aliases: "-r", type: :string, desc: "Reason for the halt"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def halt
      status = TradingHalt.halt!(reason: options[:reason])
      return emit_json(status) if json_mode?

      puts "#{RED}#{BOLD}🔴 Trading HALTED#{RESET}"
      puts "   Reason : #{status[:reason] || "(none)"}"
      puts "   As of  : #{status[:as_of]}"
    end

    # ─── resume ─────────────────────────────────────────────────────────────────
    # Two verbs behind one word, deliberately: `resume` with no argument has
    # meant "lift the global halt" since the kill switch shipped and appears in
    # runbooks as such, so ADR 0006's per-symbol resume is an OPTIONAL argument
    # rather than a rename that would break the muscle memory of whoever is
    # holding the pager.
    desc "resume [SYMBOL]", "Resume trading after a halt, or re-enable one SYMBOL (MONEY-TOUCHING — requires confirmation)"
    method_option :reason, aliases: "-r", type: :string, desc: "Why this symbol is being re-enabled"
    method_option :yes, aliases: "-y", type: :boolean, default: false,
      desc: "Confirm without an interactive prompt (required with --json)"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def resume(symbol = nil)
      return resume_symbol(symbol) if symbol.present?

      status = TradingHalt.resume!
      return emit_json(status) if json_mode?

      puts "#{GREEN}#{BOLD}🟢 Trading RESUMED#{RESET}"
      puts "   As of : #{status[:as_of]}"
    end

    # ─── suspend ────────────────────────────────────────────────────────────────
    # The brake. No confirmation, for the same reason `halt` needs none: the
    # safe direction should never be the one with friction on it.
    desc "suspend SYMBOL", "Block SYMBOL from opening new positions (exits continue)"
    method_option :reason, aliases: "-r", type: :string, desc: "Why this symbol is being suspended"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def suspend(symbol)
      Trading::SymbolSuspension.suspend!(symbol, reason: options[:reason])

      if json_mode?
        return emit_json({suspended: true, symbol: symbol, reason: options[:reason],
                          live_symbols: Trading::SymbolSuspension.live_symbols,
                          as_of: Time.current.utc.iso8601})
      end

      puts "#{RED}#{BOLD}⛔ #{symbol} SUSPENDED#{RESET} — no new entries; open positions still exit."
      puts "   Reason : #{options[:reason] || "(none)"}"
      puts "   Undo   : #{BOLD}bin/futuresbot resume #{symbol} --reason \"...\"#{RESET}"
      print_live_universe
    end

    # ─── universe ───────────────────────────────────────────────────────────────
    desc "universe", "Show which symbols may trade, which are blocked, and why (ADR 0006)"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def universe
      live = Trading::SymbolSuspension.live_symbols
      suspended = Trading::SymbolSuspension.all

      if json_mode?
        return emit_json({
          live_symbols: live,
          max_live_instruments: RapidSignalEvaluationJob.max_live_instruments,
          suspended: suspended,
          ingested_symbols: Contract.enabled.pluck(:product_id).sort,
          as_of: Time.current.utc.iso8601
        })
      end

      puts "#{BOLD}#{CYAN}🌐  Live universe#{RESET} (ADR 0006 — fails closed)"
      puts "─" * 72
      print_live_universe
      puts "  #{WHITE}Blocked:#{RESET}"
      blocked = Contract.enabled.pluck(:product_id).sort - live
      if blocked.empty?
        puts "    #{YELLOW}none#{RESET}"
      else
        blocked.each { |s| puts "    #{s}: #{Trading::SymbolSuspension.block_reason(s)}" }
      end
      puts "─" * 72
    end

    # ─── halt_status ────────────────────────────────────────────────────────────
    desc "halt_status", "Show current trading halt / kill-switch status"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def halt_status
      return emit_json(OperatorSnapshot.new.halt_status) if json_mode?

      s = TradingHalt.status
      if s[:active]
        puts "#{GREEN}#{BOLD}🟢 Trading is ACTIVE#{RESET}"
      else
        puts "#{RED}#{BOLD}🔴 Trading is HALTED#{RESET}"
        puts "   Reason : #{s[:reason] || "(none)"}"
      end
      puts "   As of  : #{s[:as_of]}"
    end

    # ─── close ──────────────────────────────────────────────────────────────────
    desc "close POSITION_ID", "Close an OPEN position (MONEY-TOUCHING — requires confirmation)"
    method_option :yes, aliases: "-y", type: :boolean, default: false,
      desc: "Confirm the close without an interactive prompt (required with --json)"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def close(position_id)
      position = Position.open.find_by(id: position_id)

      return close_failure("not_found", "No OPEN position with id #{position_id}.", position_id: position_id) unless position
      return close_failure("confirmation_required", confirmation_hint(position), position_id: position.id) unless close_confirmed?(position)

      outcome = Trading::PositionLifecycle
        .new(positions_service: Trading::CoinbasePositions.new, logger: Rails.logger)
        .close(position, reason: "cli_operator_close")

      unless outcome.success?
        return close_failure("close_failed",
          "Exchange close did not succeed — position #{position.id} (#{position.product_id}) is still OPEN.",
          position_id: position.id, product_id: position.product_id)
      end

      close_success(position, outcome)
    end

    # ─── dry_run_on ─────────────────────────────────────────────────────────────
    desc "dry_run_on", "Enable dry-run mode (simulate orders; nothing is sent to Coinbase)"
    def dry_run_on
      DryRun.enable!
      puts "#{YELLOW}#{BOLD}🧪 DRY-RUN enabled#{RESET} — orders are simulated; nothing is sent to Coinbase."
    end

    # ─── dry_run_off ────────────────────────────────────────────────────────────
    desc "dry_run_off", "Disable dry-run mode (restore live execution)"
    def dry_run_off
      DryRun.disable!
      puts "#{GREEN}#{BOLD}🟢 DRY-RUN disabled#{RESET} — LIVE execution restored."
    end

    # ─── dry_run_status ─────────────────────────────────────────────────────────
    desc "dry_run_status", "Show whether dry-run (simulated order) mode is active"
    def dry_run_status
      s = DryRun.status
      if s[:active]
        puts "#{YELLOW}#{BOLD}🧪 DRY-RUN is ACTIVE#{RESET} — orders are simulated, not sent to Coinbase."
      else
        puts "#{GREEN}#{BOLD}🟢 LIVE execution#{RESET} — dry-run is off."
      end
      puts "   As of : #{s[:as_of]}"
    end

    # ─── sentiment ──────────────────────────────────────────────────────────────
    desc "sentiment", "Show news sentiment (z-scores + recent headlines) for enabled-contract symbols"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    def sentiment
      return emit_json(OperatorSnapshot.new.sentiment) if json_mode?

      data = OperatorSnapshot.new.sentiment
      puts "#{BOLD}#{CYAN}📰  Sentiment#{RESET}"
      puts "─" * 60
      print_sentiment_section
      puts "  #{WHITE}Recent headlines:#{RESET}"
      if data[:recent_events].empty?
        puts "    #{YELLOW}none#{RESET}"
      else
        data[:recent_events].first(6).each do |e|
          score = e[:score].nil? ? "  ?  " : format("%+.2f", e[:score])
          puts "    [#{score}] #{e[:source]}: #{e[:title].to_s[0, 60]}"
        end
      end
    end

    # ─── backtests ──────────────────────────────────────────────────────────────
    desc "backtests", "List persisted backtest runs (metrics + cost-gate verdict)"
    method_option :json, type: :boolean, default: false, desc: "Emit machine-readable JSON (no ANSI)"
    method_option :limit, type: :numeric, default: 15, desc: "How many runs to show"
    method_option :symbol, type: :string, desc: "Filter by symbol"
    def backtests
      data = OperatorSnapshot.new.backtests(limit: options[:limit].to_i)
      rows = data[:runs]
      rows = rows.select { |r| r[:symbol] == options[:symbol] } if options[:symbol].present?
      return emit_json(data.merge(runs: rows)) if json_mode?

      puts "#{BOLD}#{CYAN}🧪  Backtest runs#{RESET}"
      puts "─" * 92
      if rows.empty?
        puts "  #{YELLOW}none recorded#{RESET}"
        return
      end
      puts "  #{WHITE}#{"id".ljust(5)}#{"gate".ljust(7)}#{"symbol".ljust(19)}#{"kind".ljust(14)}" \
           "#{"step".ljust(6)}#{"trades".ljust(8)}#{"win%".ljust(7)}#{"expectancy".ljust(12)}ran#{RESET}"
      rows.each { |r| puts backtest_line(r) }
      puts "─" * 92
      puts "  #{WHITE}detail:#{RESET} /backtest_runs/<id> in the web UI"
    end

    # ─── mcp ────────────────────────────────────────────────────────────────────
    desc "mcp", "Run the MCP server (stdio JSON-RPC) exposing bot state and control tools to Claude Code"
    def mcp
      Mcp::Server.new.run
    end

    # ─── version ────────────────────────────────────────────────────────────────
    desc "version", "Show FuturesBot version information"
    def version
      puts "#{BOLD}FuturesBot#{RESET} – Coinbase Futures Trading Bot"
      puts "Rails #{Rails.version} / Ruby #{RUBY_VERSION}"
      puts "Run #{CYAN}bin/futuresbot help#{RESET} for available commands."
    end

    private

    # True when JSON output is requested via the --json flag or FUTURESBOT_JSON.
    def json_mode?
      options[:json] || ENV["FUTURESBOT_JSON"].present?
    end

    # Emit a single JSON document to stdout with no ANSI codes, for machine
    # consumers (the /futuresbot skill and MCP server).
    def emit_json(data)
      puts JSON.generate(data)
    end

    # ── close helpers ────────────────────────────────────────────────────────────

    # ADR 0005: money-touching operator actions require explicit confirmation.
    # `--yes` is that confirmation; without it a human gets an interactive
    # prompt. `--json` callers (the /futuresbot skill, scripts) must never be
    # blocked on a prompt they cannot answer, so JSON without `--yes` refuses
    # outright — the same shape as Mcp::Server#close_position's `confirm: true`.
    def close_confirmed?(position)
      return true if options[:yes]
      return false if json_mode?

      $stdout.print "#{YELLOW}#{BOLD}⚠ MONEY-TOUCHING#{RESET} #{close_summary(position)}\n" \
                    "Type #{BOLD}yes#{RESET} to close it: "
      $stdin.gets.to_s.strip.casecmp("yes").zero?
    end

    def confirmation_hint(position)
      "Not confirmed — #{close_summary(position)} left OPEN. " \
        "Re-run with #{BOLD}--yes#{RESET} to confirm."
    end

    def close_summary(position)
      "position #{position.id} (#{position.product_id} #{position.side} #{position.size})"
    end

    def close_failure(error, message, **details)
      return emit_json({closed: false, error: error, **details, as_of: Time.current.utc.iso8601}) if json_mode?

      $stdout.puts "#{RED}#{BOLD}✖ Close aborted#{RESET} — #{message}"
    end

    def close_success(position, outcome)
      if json_mode?
        return emit_json({closed: true, position_id: position.id, product_id: position.product_id,
                          close_price: outcome.close_price, as_of: Time.current.utc.iso8601})
      end

      $stdout.puts "#{GREEN}#{BOLD}✅ Closed#{RESET} position #{position.id} " \
                   "(#{position.product_id}) at #{outcome.close_price}"
    end

    # ── universe helpers ─────────────────────────────────────────────────────────

    # Re-enabling a symbol is what puts an instrument back on the order path, so
    # it carries the same confirmation contract as `close`: `--yes`, an
    # interactive prompt for a human, and an outright refusal for `--json`
    # callers who cannot answer a prompt.
    def resume_symbol(symbol)
      unless resume_confirmed?(symbol)
        if json_mode?
          return emit_json({resumed: false, error: "confirmation_required", symbol: symbol,
                            as_of: Time.current.utc.iso8601})
        end
        return $stdout.puts "#{RED}#{BOLD}✖ Resume aborted#{RESET} — Not confirmed; " \
                            "#{symbol} stays blocked. Re-run with #{BOLD}--yes#{RESET}."
      end

      Trading::SymbolSuspension.enable!(symbol, reason: options[:reason])
      live = Trading::SymbolSuspension.live_symbols

      if json_mode?
        return emit_json({resumed: true, symbol: symbol, reason: options[:reason],
                          live_symbols: live, as_of: Time.current.utc.iso8601})
      end

      puts "#{GREEN}#{BOLD}🟢 #{symbol} ENABLED for trading#{RESET}"
      puts "   Reason : #{options[:reason] || "(none)"}"
      print_live_universe
      warn_over_instrument_cap(live)
    end

    def resume_confirmed?(symbol)
      return true if options[:yes]
      return false if json_mode?

      $stdout.print "#{YELLOW}#{BOLD}⚠ MONEY-TOUCHING#{RESET} re-enabling #{symbol} lets it open NEW positions.\n" \
                    "Type #{BOLD}yes#{RESET} to enable it: "
      $stdin.gets.to_s.strip.casecmp("yes").zero?
    end

    def print_live_universe
      live = Trading::SymbolSuspension.live_symbols
      puts "   #{WHITE}Live symbols:#{RESET} #{live.empty? ? "#{YELLOW}none#{RESET}" : live.join(", ")} " \
           "(#{live.size}/#{RapidSignalEvaluationJob.max_live_instruments})"
    end

    # The cap is enforced at the entry gate, not here — refusing the resume
    # would leave an operator unable to swap which instrument is live. Say it
    # plainly instead, so nobody wonders why the newly-enabled symbol is quiet.
    def warn_over_instrument_cap(live)
      cap = RapidSignalEvaluationJob.max_live_instruments
      return if live.size <= cap

      puts "#{YELLOW}#{BOLD}⚠ #{live.size} symbols enabled but MAX_LIVE_INSTRUMENTS=#{cap}#{RESET} — " \
           "entries are rejected until you suspend #{live.size - cap} of them."
    end

    # Prints simulated (paper) account state for `status` when dry-run is active
    # or paper positions exist: equity, realized/unrealized PnL, and open count.
    def print_paper_section
      account = PaperAccount.new
      return unless DryRun.active? || account.any?

      puts "  #{WHITE}Paper account:#{RESET} #{YELLOW}(simulated)#{RESET}"
      puts "    Equity: $#{format("%.2f", account.equity)}  " \
           "(realized #{format_signed(account.realized_pnl)}, unrealized #{format_signed(account.unrealized_pnl)})"
      puts "    Open paper positions: #{account.open_positions.count}"
      puts "─" * 40
    end

    def format_signed(amount)
      format("%+.2f", amount)
    end

    # Prints a sentiment pipeline summary for `status`: per enabled-contract
    # symbol z-score/count, plus last-event age and a stale/missing warning.
    # Read-only (Sentiment::Snapshot performs no writes).
    # cost_gate_passed (#353) is the verdict that matters, so it leads the row.
    # nil means no verdict yet (pending/running/failed) — shown distinctly from
    # a failure rather than collapsed into one.
    def backtest_line(run)
      gate = case run[:cost_gate_passed]
      when true then "#{GREEN}PASS#{RESET}   "
      when false then "#{RED}FAIL#{RESET}   "
      else "#{YELLOW}—#{RESET}      "
      end
      win = run[:win_rate] ? "#{(run[:win_rate].to_f * 100).round(1)}%" : "—"
      exp = run[:expectancy] ? run[:expectancy].to_f.round(3).to_s : "—"
      ran = run[:created_at].to_s[5, 11].to_s.tr("T", " ")
      "  #{run[:id].to_s.ljust(5)}#{gate}#{run[:symbol].to_s.ljust(19)}" \
        "#{run[:kind].to_s.ljust(14)}#{run[:step].to_s.ljust(6)}" \
        "#{run[:trade_count].to_s.ljust(8)}#{win.ljust(7)}#{exp.ljust(12)}#{ran}"
    end

    def print_sentiment_section
      snap = Sentiment::Snapshot.new.call
      puts "  #{WHITE}Sentiment:#{RESET}"

      if snap.symbols.empty? && snap.last_event_at.nil?
        puts "    #{YELLOW}No sentiment data yet.#{RESET}"
        return
      end

      snap.symbols.each do |s|
        line = if s.z_score.nil?
          "    #{s.symbol}: #{YELLOW}no data#{RESET}"
        else
          "    #{s.symbol}: z=#{format("%+.1f", s.z_score)} (#{s.event_count}/#{s.window})"
        end
        puts line
      end

      puts "    #{sentiment_freshness(snap)}"
    end

    # Why the bot is (or isn't) acting (issue #436): sentiment predictiveness +
    # active protections. Full 1/4/24h detail is in `status --json`.
    def print_indicators_section
      puts "  #{WHITE}Indicators:#{RESET}"
      Cli::IndicatorsPresenter.lines(OperatorSnapshot.new.indicators).each { |line| puts "  #{line}" }
    rescue => e
      puts "    #{YELLOW}indicators unavailable: #{e.message}#{RESET}"
    end

    def sentiment_freshness(snap)
      if snap.last_event_at.nil?
        "#{YELLOW}⚠ STALE — no sentiment events#{RESET}"
      elsif snap.stale?
        age = time_ago(snap.last_event_at)
        "#{YELLOW}⚠ STALE — last event #{age} ago#{RESET}"
      else
        "Last event: #{time_ago(snap.last_event_at)} ago"
      end
    end

    def time_ago(time)
      seconds = (Time.current - time).to_i
      return "#{seconds}s" if seconds < 60
      return "#{seconds / 60}m" if seconds < 3600

      "#{seconds / 3600}h"
    end

    def sync_startup_positions
      result = StartupPositionSync.new.call
      return unless $stdout.tty?
      return if result.status == :skipped

      color = (result.status == :ok) ? GREEN : YELLOW
      icon = (result.status == :ok) ? "✓" : "⚠"
      puts "#{color}#{icon}#{RESET} #{result.message}\n"
    end

    # ── Formatting helpers ───────────────────────────────────────────────────────

    def colorize_count(count)
      (count > 0) ? "#{GREEN}#{BOLD}#{count}#{RESET}" : "#{WHITE}#{count}#{RESET}"
    end

    def format_liveness(name)
      hb = Heartbeat.status(name)
      if hb[:stale]
        age = hb[:age_seconds] ? "#{hb[:age_seconds]}s ago" : "never"
        "#{RED}#{BOLD}⚠ STALE#{RESET} #{WHITE}(last beat #{age} — is the bot running?)#{RESET}"
      else
        "#{GREEN}live#{RESET} #{WHITE}(#{hb[:age_seconds]}s ago)#{RESET}"
      end
    end

    # Columns are ID / Product / Side / Entry / Size / PnL / Type.
    #
    # This used to read `%w[ID Product Side Entry Price Type]` — six labels for a
    # row supplying id, product, side, entry_price, SIZE, type — so the column
    # labelled "Price" showed the contract count. A 1-contract position rendered
    # as "Price 1.0", which reads as a catastrophic quote on an $80 instrument.
    # "Entry Price" was one label that %w split into two columns.
    def format_positions_header
      "  #{BOLD}%-6s  %-20s  %-6s  %-12s  %-8s  %-12s  %-8s#{RESET}" %
        %w[ID Product Side Entry Size PnL Type]
    end

    # Rows come from OperatorSnapshot, the canonical position view (#290) that
    # `positions --json` already used. The human table hand-rolled its own read
    # off Position.open and so had no mark price and no PnL — the two numbers an
    # operator is actually looking for. One source now, so both views agree.
    def format_position_row(row)
      side_color = (row[:side].to_s.upcase == "LONG") ? GREEN : RED
      product = row[:paper] ? "🧪#{row[:product_id]}" : row[:product_id].to_s
      pnl = row[:unrealized_pnl]
      pnl_text = pnl ? "%+.2f" % pnl : "—"
      pnl_color = if pnl.nil?
        RESET
      else
        (pnl >= 0) ? GREEN : RED
      end

      "  %-6s  %-20s  #{side_color}%-6s#{RESET}  %-12s  %-8s  #{pnl_color}%-12s#{RESET}  %-8s" % [
        row[:id],
        product.truncate(20),
        row[:side],
        row[:entry_price]&.round(2) || "N/A",
        row[:size],
        pnl_text,
        row[:day_trading] ? "Day" : "Swing"
      ]
    end

    def format_signals_header
      "  #{BOLD}%-6s  %-20s  %-6s  %-8s  %-12s  %-6s#{RESET}" %
        %w[ID Symbol Side Type Strategy Conf%]
    end

    def format_signal_row(sig)
      side_color = sig.long? ? GREEN : RED
      conf_color = if sig.confidence >= 80
        GREEN
      else
        ((sig.confidence >= 60) ? YELLOW : RED)
      end
      "  %-6s  %-20s  #{side_color}%-6s#{RESET}  %-8s  %-12s  #{conf_color}%-6s#{RESET}" % [
        sig.id,
        sig.symbol.to_s.truncate(20),
        sig.side,
        sig.signal_type,
        sig.strategy_name.to_s.truncate(12),
        sig.confidence.to_i
      ]
    end
  end
end

# Backward-compatibility alias for existing call sites.
FuturesBotCli = Cli::FuturesBotCli unless defined?(FuturesBotCli)
