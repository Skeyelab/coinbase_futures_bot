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
      key = msg.to_s
      case key
      when "q", "Q", "ctrl+c", "esc"
        [self, Bubbletea.quit]
      when "1", "2", "3", "4", "5"
        @layout = @layout.switch_to(key)
        [self, nil]
      when "?", "/"
        [self, operation_picker_form]
      else
        dispatch_operation(key.downcase) || [self, nil]
      end
    end

    def dispatch_operation(key)
      entry = Tui::OperationsCatalog.find(key)
      return nil unless entry
      return nil unless operation_available?(entry)

      case key
      when "r"
        refresh_data
        [self, nil]
      when "i"
        run_import_async
        [self, nil]
      when "t"
        [self, edit_take_profit_form]
      when "s"
        [self, edit_stop_loss_form]
      when "c"
        [self, close_position_form]
      when "o"
        [self, reconcile_form]
      when "h"
        [self, halt_toggle_form]
      when "m"
        toggle_realtime_monitoring
        [self, nil]
      end
    end

    def operation_available?(entry)
      entry.tabs == :all || Array(entry.tabs).include?(@layout.active_tab)
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
      prices = Tui::Components::PricesPanel.new(futures, spot)
      [
        panel("Futures", futures.size, prices.futures_body),
        panel("Spot", spot.size, prices.spot_body)
      ].join("\n")
    end

    def health_view
      panel(
        "Ops",
        nil,
        Tui::Components::HealthPanel.new(
          data: @data,
          rtm_status: RealtimeMonitoring::Session.current.status
        ).render
      )
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
      hints = Tui::OperationsCatalog.for_tab(@layout.active_tab).map do |entry|
        "[#{entry.key}]#{entry.label.downcase.split.first}"
      end
      dim.render("  [1-5] tabs [q]uit #{hints.join(" ")}")
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

    def edit_take_profit_form
      Bubbletea.exec(
        -> {
          id_str = Gum.input(header: "Edit take-profit", placeholder: "OPEN position id (blank=cancel)")
          Tui::Forms::EditPositionTarget.run(field: :take_profit, id_str: id_str)
        },
        message: TickMessage.new
      )
    end

    def operation_picker_form
      active_tab = @layout.active_tab
      Bubbletea.exec(
        -> {
          key = Tui::Forms::OperationPicker.run(active_tab: active_tab)
          next unless key

          case key
          when "r" then Tui::DataLoader.load
          when "i"
            PositionImportService.new.import_positions_from_coinbase
          when "t"
            id_str = Gum.input(header: "Edit take-profit", placeholder: "OPEN position id (blank=cancel)")
            Tui::Forms::EditPositionTarget.run(field: :take_profit, id_str: id_str)
          when "s"
            id_str = Gum.input(header: "Edit stop-loss", placeholder: "OPEN position id (blank=cancel)")
            Tui::Forms::EditPositionTarget.run(field: :stop_loss, id_str: id_str)
          when "c"
            id_str = Gum.input(header: "Close position", placeholder: "OPEN position id (blank=cancel)")
            Tui::Forms::ClosePosition.run(id_str)
          when "o"
            Tui::Forms::Reconcile.run
          when "h"
            Tui::Forms::HaltToggle.run
          when "m"
            RealtimeMonitoring::Session.current.toggle!
          end
        },
        message: TickMessage.new
      )
    end

    def toggle_realtime_monitoring
      Thread.new do
        result = RealtimeMonitoring::Session.current.toggle!
        if result[:success]
          set_flash(:ok, result[:message])
        else
          set_flash(:error, result[:error])
        end
      rescue => e
        set_flash(:error, "Real-time toggle failed: #{e.message}")
      end
    end

    def edit_stop_loss_form
      Bubbletea.exec(
        -> {
          id_str = Gum.input(header: "Edit stop-loss", placeholder: "OPEN position id (blank=cancel)")
          Tui::Forms::EditPositionTarget.run(field: :stop_loss, id_str: id_str)
        },
        message: TickMessage.new
      )
    end
  end
end
