# frozen_string_literal: true

require "thor"
require_relative "tui_dashboard"

# Cli::FuturesBotCli provides a Thor-based command-line interface for
# interacting with the Coinbase Futures Bot from the shell.
#
# Usage:
#   bin/futuresbot dashboard         # Real-time full-screen TUI dashboard
#   bin/futuresbot chat              # Start interactive chat
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
    desc "dashboard", "Launch the real-time full-screen TUI dashboard"
    method_option :refresh, aliases: "-i", type: :numeric, default: TuiDashboard::DEFAULT_REFRESH,
      desc: "Auto-refresh interval in seconds"
    def dashboard
      sync_positions_on_startup
      TuiDashboard.new(refresh_interval: options[:refresh]).start
    end

    # ─── chat ───────────────────────────────────────────────────────────────────
    desc "chat", "Start an interactive AI-powered trading chat session"
    method_option :resume, aliases: "-r", type: :boolean, default: false,
      desc: "Resume the most recent session"
    method_option :session_id, aliases: "-s", type: :string,
      desc: "Resume a specific session by ID"
    def chat
      print_banner
      sync_positions_on_startup

      session_id = resolve_session_id(options)
      bot = ChatBotService.new(session_id)

      print_session_info(bot, session_id)
      puts "#{CYAN}Type #{BOLD}'help'#{RESET}#{CYAN} for available commands or #{BOLD}'quit'#{RESET}#{CYAN} to exit.#{RESET}\n\n"

      trap_interrupt

      loop do
        print "#{BOLD}#{CYAN}FuturesBot>#{RESET} "

        begin
          input = $stdin.gets
          break unless input  # EOF (Ctrl+D)

          input = input.chomp.strip
          next if input.empty?

          break if quit_command?(input)

          next if handle_local_command(input, bot, session_id)

          print "#{YELLOW}Processing…#{RESET}"
          response = bot.process(input)
          print "\r#{" " * 14}\r"  # clear "Processing…" line
          puts response
          puts
        rescue Interrupt
          puts "\n\n#{GREEN}👋  Goodbye! Chat session ended.#{RESET}"
          break
        rescue => e
          puts "\n#{RED}❌  Error: #{e.message}#{RESET}"
          puts "Please try again or type 'quit' to exit.\n"
        end
      end

      print_session_summary(bot, session_id)
    end

    # ─── status ─────────────────────────────────────────────────────────────────
    desc "status", "Show the current bot and system status"
    def status
      day_pos = Position.open.day_trading.count
      swing_pos = Position.open.swing_trading.count
      signals = SignalAlert.active.count
      sessions = ChatSession.active.count

      puts "#{BOLD}#{CYAN}📊  FuturesBot Status#{RESET}"
      puts "─" * 40
      puts "  #{WHITE}Day-trading positions:  #{RESET}#{colorize_count(day_pos)}"
      puts "  #{WHITE}Swing positions:        #{RESET}#{colorize_count(swing_pos)}"
      puts "  #{WHITE}Active signals:         #{RESET}#{colorize_count(signals)}"
      puts "  #{WHITE}Chat sessions:          #{RESET}#{sessions}"
      puts "─" * 40
      puts "  #{WHITE}Status:#{RESET} #{GREEN}#{BOLD}operational#{RESET}"
    end

    # ─── positions ──────────────────────────────────────────────────────────────
    desc "positions", "List all open trading positions"
    method_option :type, aliases: "-t", type: :string,
      desc: "Filter by type: day | swing"
    method_option :limit, aliases: "-n", type: :numeric, default: 20,
      desc: "Maximum number of positions to display"
    def positions
      scope = Position.open
      scope = scope.day_trading if options[:type] == "day"
      scope = scope.swing_trading if options[:type] == "swing"
      scope = scope.limit(options[:limit])
      rows = scope.to_a

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
    def signals
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

    # ─── version ────────────────────────────────────────────────────────────────
    desc "version", "Show FuturesBot version information"
    def version
      puts "#{BOLD}FuturesBot#{RESET} – Coinbase Futures Trading Bot"
      puts "Rails #{Rails.version} / Ruby #{RUBY_VERSION}"
      puts "Run #{CYAN}bin/futuresbot help#{RESET} for available commands."
    end

    private

    # Pulls open futures positions from Coinbase into the local DB so the bot
    # matches exchange state after restarts. Non-fatal if the API is unavailable.
    def sync_positions_on_startup
      return if skip_position_sync?

      result = PositionImportService.new.import_positions_from_coinbase
      return unless $stdout.tty?

      puts "#{GREEN}✓#{RESET} Positions synced from Coinbase " \
           "(#{result[:imported]} new, #{result[:updated]} updated, " \
           "#{result[:total_coinbase]} on exchange)\n"
    rescue => e
      Rails.logger.warn("[FuturesBotCli] Position sync on startup failed: #{e.message}")
      puts "#{YELLOW}⚠#{RESET} Position sync skipped: #{e.message}\n" if $stdout.tty?
    end

    def skip_position_sync?
      ENV["FUTURESBOT_SKIP_POSITION_SYNC"].present?
    end

    # ── Session helpers ─────────────────────────────────────────────────────────

    def resolve_session_id(opts)
      if opts[:resume]
        resume_last_session
      elsif opts[:session_id]
        opts[:session_id]
      else
        SecureRandom.uuid
      end
    end

    def resume_last_session
      last = ChatSession.active.recent.first
      if last
        last.session_id
      else
        puts "#{YELLOW}No active sessions found – starting a new session.#{RESET}"
        SecureRandom.uuid
      end
    end

    def print_banner
      puts
      puts "#{BOLD}#{CYAN}🤖  FuturesBot Chat Interface#{RESET}"
      puts "#{CYAN}============================#{RESET}"
    end

    def print_session_info(bot, session_id)
      summary = bot.session_summary
      if summary[:total_interactions] > 0
        puts "#{GREEN}Resuming session #{session_id[0..7]} " \
             "(#{summary[:total_interactions]} messages, " \
             "#{summary[:profitable_messages]} profitable)#{RESET}"
      else
        puts "#{GREEN}Starting new session #{session_id[0..7]}#{RESET}"
      end
    end

    def print_session_summary(bot, session_id)
      summary = bot.session_summary
      return unless summary && summary[:total_interactions] > 0

      puts "\n#{BOLD}📊  Session Summary#{RESET}"
      puts "   Commands processed: #{summary[:total_interactions]}"
      puts "   Profitable messages: #{summary[:profitable_messages]}"
      puts "   Session ID: #{session_id[0..7]}…"
    end

    def trap_interrupt
      Signal.trap("INT") do
        puts "\n\n#{GREEN}👋  Goodbye! Chat session ended.#{RESET}"
        exit(0)
      end
    end

    # ── Command routing inside chat ──────────────────────────────────────────────

    def quit_command?(input)
      if %w[quit exit bye].include?(input.downcase)
        puts "\n#{GREEN}👋  Goodbye! Chat session ended.#{RESET}"
        true
      else
        false
      end
    end

    # Returns true when the command was handled locally (no AI call needed).
    def handle_local_command(input, bot, session_id)
      case input.downcase
      when /^history\s*(\d+)?$/
        show_local_history(bot, Regexp.last_match(1)&.to_i || 10)
      when /^search\s+(.+)$/
        show_search_results(bot, Regexp.last_match(1).strip)
      when /^sessions$/
        show_sessions_list(bot, session_id)
      when /^context[-_]?status$/
        show_context_status(bot)
      when /^new[-_]?session(?:\s+(.+))?$/
        # Handled inline but we still return true
        show_new_session_hint
      else
        return false
      end
      true
    end

    def show_local_history(bot, limit)
      memory = ChatMemoryService.new(bot.instance_variable_get(:@session_id))
      history = memory.recent_interactions(limit)

      puts "#{BOLD}📜  Recent History#{RESET} (#{limit} messages):"
      if history.any?
        history.each_with_index do |item, i|
          ts = Time.parse(item[:timestamp]).strftime("%H:%M")
          puts "  #{i + 1}. #{YELLOW}[#{ts}]#{RESET} #{item[:input].to_s.truncate(80)}"
        end
      else
        puts "  #{YELLOW}No history found.#{RESET}"
      end
      puts
    end

    def show_search_results(bot, query)
      memory = ChatMemoryService.new(bot.instance_variable_get(:@session_id))
      results = memory.search_history(query)

      puts "#{BOLD}🔍  Search Results#{RESET} for '#{query}':"
      if results.any?
        results.each_with_index do |r, i|
          ts = r[1].strftime("%m/%d %H:%M")
          impact = r[2].upcase
          puts "  #{i + 1}. #{YELLOW}[#{ts}]#{RESET} [#{impact}] #{r[0].to_s.truncate(100)}"
        end
      else
        puts "  #{YELLOW}No results found.#{RESET}"
      end
      puts
    end

    def show_sessions_list(bot, current_id)
      sessions = ChatSession.active.recent.limit(10)

      # Fetch profitable-message counts in one query to avoid N+1.
      profitable_counts = ChatMessage.profitable
        .where(chat_session_id: sessions.map(&:id))
        .group(:chat_session_id)
        .count

      puts "#{BOLD}💬  Active Chat Sessions#{RESET}:"
      if sessions.any?
        sessions.each_with_index do |session, i|
          marker = (session.session_id == current_id) ? "#{GREEN}→#{RESET}" : " "
          profitable = profitable_counts[session.id] || 0
          puts "  #{marker} #{i + 1}. #{session.session_id[0..7]} – #{session.name || "Unnamed"}"
          puts "       Messages: #{session.message_count} (#{profitable} profitable)"
          puts "       Last: #{session.last_activity&.strftime("%m/%d %H:%M") || "N/A"}"
        end
      else
        puts "  #{YELLOW}No active sessions found.#{RESET}"
      end
      puts
    end

    def show_context_status(bot)
      summary = bot.session_summary
      memory = ChatMemoryService.new(bot.instance_variable_get(:@session_id))
      ctx_len = memory.context_for_ai(4000).length

      puts "#{BOLD}🧠  Context Status#{RESET}:"
      puts "  Session:        #{summary[:session_id][0..7]}"
      puts "  Messages:       #{summary[:total_interactions]} (#{summary[:profitable_messages]} profitable)"
      puts "  Context length: #{ctx_len} chars (~#{(ctx_len / 4).to_i} tokens)"
      puts "  Last activity:  #{summary[:last_activity] || "N/A"}"
      puts
    end

    def show_new_session_hint
      puts "#{YELLOW}Tip: run #{BOLD}bin/futuresbot chat#{RESET}#{YELLOW} to start a brand-new session.#{RESET}"
      puts
    end

    # ── Formatting helpers ───────────────────────────────────────────────────────

    def colorize_count(count)
      (count > 0) ? "#{GREEN}#{BOLD}#{count}#{RESET}" : "#{WHITE}#{count}#{RESET}"
    end

    def format_positions_header
      "  #{BOLD}%-6s  %-20s  %-6s  %-12s  %-12s  %-10s#{RESET}" %
        %w[ID Product Side Entry Price Type]
    end

    def format_position_row(pos)
      side_color = pos.long? ? GREEN : RED
      "  %-6s  %-20s  #{side_color}%-6s#{RESET}  %-12s  %-12s  %-10s" % [
        pos.id,
        pos.product_id.to_s.truncate(20),
        pos.side,
        pos.entry_price&.round(2) || "N/A",
        pos.size,
        pos.day_trading? ? "Day" : "Swing"
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
