# frozen_string_literal: true

require "bubbletea"
require "lipgloss"

module Tui
  class TickMessage < Bubbletea::Message; end

  class App
    include Bubbletea::Model

    TICK_INTERVAL = 1.0

    def initialize
      @data = {}
      @flash = nil
      @flash_until = nil
      @layout = Tui::Layout.new
    end

    def init
      [self, schedule_tick]
    end

    def update(message)
      case message
      when Bubbletea::KeyMessage
        handle_key(message)
      when TickMessage
        refresh_data
        [self, schedule_tick]
      when Bubbletea::WindowSizeMessage
        @layout = @layout.with_width(message.width)
        [self, nil]
      else
        [self, nil]
      end
    end

    def view
      lines = []
      lines << header_view
      lines << tab_bar_view
      lines << status_bar_view
      lines << tab_content_view
      lines << flash_view if flash_active?
      lines << footer_view
      lines.compact.join("\n")
    end

    private

    def handle_key(msg)
      case msg.to_s
      when "q", "Q", "ctrl+c", "esc"
        [self, Bubbletea.quit]
      when "r", "R"
        refresh_data
        [self, nil]
      when "1", "2", "3", "4", "5"
        @layout = @layout.switch_to(msg.to_s)
        [self, nil]
      when "p", "P", "left"
        @layout = @layout.switch_to_tab(:positions)
        [self, nil]
      when "s", "S", "right"
        @layout = @layout.switch_to_tab(:signals)
        [self, nil]
      when "i", "I"
        run_import_async
        [self, nil]
      when "c", "C"
        [self, close_position_form]
      when "o", "O"
        [self, reconcile_form]
      when "h", "H"
        [self, halt_toggle_form]
      else
        [self, nil]
      end
    end

    def schedule_tick
      Bubbletea.tick(TICK_INTERVAL) { TickMessage.new }
    end

    def refresh_data
      @data = Tui::DataLoader.load
    rescue => e
      set_flash(:error, "Refresh error: #{e.message}")
    end

    def header_view
      ts = Time.now.strftime("%H:%M:%S")
      title_style = Lipgloss::Style.new.bold(true).foreground("14")
      dim_style = Lipgloss::Style.new.foreground("240")
      "#{title_style.render("🤖  FuturesBot")}  #{dim_style.render(ts)}"
    end

    def tab_bar_view
      Tui::Components::TabBar.new(@layout).render
    end

    def status_bar_view
      Tui::Components::StatusBar.new(@data).render
    end

    def tab_content_view
      case @layout.active_tab
      when :overview then overview_view
      when :positions then framed_positions_view
      when :signals then framed_signals_view
      when :market then framed_market_view
      when :health then health_view
      end
    end

    def overview_view
      positions = (@data[:positions] || []).first(3)
      signals = (@data[:signals] || []).first(3)
      sections = [
        panel("Positions", positions.size, Tui::Components::PositionsTable.new(positions, @data[:live_prices] || {}, height: 5).render),
        panel("Signals", signals.size, Tui::Components::SignalsTable.new(signals, height: 5).render),
        panel("Market", (@data[:futures_live_prices] || []).size + (@data[:spot_live_prices] || []).size,
          Tui::Components::PricesPanel.new(@data[:futures_live_prices] || [], @data[:spot_live_prices] || []).render)
      ]
      sections.join("\n")
    end

    def framed_positions_view
      positions = @data[:positions] || []
      panel("Positions", positions.size,
        Tui::Components::PositionsTable.new(positions, @data[:live_prices] || {}).render)
    end

    def framed_signals_view
      signals = @data[:signals] || []
      panel("Signals", signals.size, Tui::Components::SignalsTable.new(signals).render)
    end

    def framed_market_view
      futures = @data[:futures_live_prices] || []
      spot = @data[:spot_live_prices] || []
      panel("Market", futures.size + spot.size,
        Tui::Components::PricesPanel.new(futures, spot).render)
    end

    def health_view
      panel("Health", nil, Lipgloss::Style.new.foreground("240").render("  Eval, sentiment, and tick freshness — wired in #249"))
    end

    def panel(title, count, content)
      Tui::Components::PanelFrame.new(title: title, count: count, width: @layout.width - 2).render(content)
    end

    def flash_view
      return unless flash_active?

      color = if @flash[:level] == :error
        "9"
      elsif @flash[:level] == :warn
        "11"
      else
        "10"
      end
      Lipgloss::Style.new.foreground(color).render("  #{@flash[:text]}")
    end

    def footer_view
      dim = Lipgloss::Style.new.foreground("240")
      dim.render("  [1-5] tabs [q]uit [r]efresh [p]os [s]igs [i]mport [c]lose [o]reconcile [h]alt")
    end

    def flash_active?
      @flash && @flash_until && Time.now < @flash_until
    end

    def set_flash(level, text, seconds: 8)
      @flash = {level: level, text: text}
      @flash_until = Time.now + seconds
    end

    def run_import_async
      Thread.new do
        svc = PositionImportService.new
        result = svc.import_positions_from_coinbase
        reconciled = result[:reconciled].to_i
        msg = "Synced: #{result[:imported]} new, #{result[:updated]} updated"
        msg += ", #{reconciled} reconciled" if reconciled.positive?
        set_flash(:ok, msg)
      rescue => e
        set_flash(:error, "Sync failed: #{e.message}")
      end
    end

    def close_position_form
      Bubbletea.exec(
        -> {
          id_str = Gum.input(header: "Close position", placeholder: "OPEN position id (blank=cancel)")
          Tui::Forms::ClosePosition.run(id_str)
        },
        message: TickMessage.new
      )
    end

    def reconcile_form
      Bubbletea.exec(
        -> {
          Tui::Forms::Reconcile.run
        },
        message: TickMessage.new
      )
    end

    def halt_toggle_form
      Bubbletea.exec(
        -> {
          Tui::Forms::HaltToggle.run
        },
        message: TickMessage.new
      )
    end
  end
end
