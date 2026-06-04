# frozen_string_literal: true

require "bubbles"
require "lipgloss"

module Tui
  module Components
    class SignalsTable
      COLUMNS = [
        {title: "ID", width: 6},
        {title: "Symbol", width: 16},
        {title: "Side", width: 6},
        {title: "Type", width: 9},
        {title: "Conf%", width: 6},
        {title: "Strategy", width: 20}
      ].freeze

      def initialize(signals, height: 8)
        @signals = signals
        @table = Bubbles::Table.new(columns: COLUMNS, rows: build_rows, height: height)
        style_table
      end

      def update(message)
        @table, cmd = @table.update(message)
        [self, cmd]
      end

      def rows=(signals)
        @signals = signals
        @table.rows = build_rows
      end

      def render
        label = Lipgloss::Style.new.bold(true).foreground("14").render("  Active Signals")
        count = Lipgloss::Style.new.foreground("240").render("  (#{@signals.size})")
        "#{label}#{count}\n#{@table.view}"
      end

      private

      def build_rows
        @signals.map do |sig|
          [
            sig.id.to_s,
            sig.symbol.to_s[0, 16],
            sig.side.to_s,
            sig.signal_type.to_s,
            sig.confidence.to_i.to_s,
            sig.strategy_name.to_s[0, 20]
          ]
        end
      end

      def style_table
        @table.header_style = Lipgloss::Style.new.bold(true).foreground("240")
        @table.selected_style = Lipgloss::Style.new.bold(true).foreground("11")
      end
    end
  end
end
