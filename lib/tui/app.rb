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
      @show_positions = true
      @show_signals = true
      @width = 120
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
        @width = message.width
        [self, nil]
      else
        [self, nil]
      end
    end

    def view
      lines = []
      lines << header_view
      lines << status_bar_view
      lines << positions_view if @show_positions
      lines << signals_view if @show_signals
      lines << prices_view
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
      when "p", "P", "left"
        @show_positions = !@show_positions
        [self, nil]
      when "s", "S", "right"
        @show_signals = !@show_signals
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

    def status_bar_view
      Tui::Components::StatusBar.new(@data).render
    end

    def positions_view
      Tui::Components::PositionsTable.new(@data[:positions] || [], @data[:live_prices] || {}).render
    end

    def signals_view
      Tui::Components::SignalsTable.new(@data[:signals] || []).render
    end

    def prices_view
      Tui::Components::PricesPanel.new(@data[:futures_live_prices] || [], @data[:spot_live_prices] || []).render
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
      dim.render("  [q]uit [r]efresh [p]os [s]igs [i]mport [c]lose [o]reconcile [h]alt")
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
        set_flash(:ok, "Synced: #{result[:imported]} new, #{result[:updated]} updated")
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
