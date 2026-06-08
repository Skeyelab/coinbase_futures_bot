# frozen_string_literal: true

require "bubbles"
require "lipgloss"

module Tui
  module Components
    class PositionsTable
      COLUMNS = [
        {title: "ID", width: 6},
        {title: "Product", width: 18},
        {title: "Side", width: 6},
        {title: "Entry", width: 9},
        {title: "Size", width: 6},
        {title: "Type", width: 5},
        {title: "TP", width: 8},
        {title: "SL", width: 9},
        {title: "U.PnL", width: 10}
      ].freeze

      def initialize(positions, live_prices = {}, height: 10)
        @positions = positions
        @live_prices = live_prices
        @table = Bubbles::Table.new(columns: COLUMNS, rows: build_rows, height: height)
        style_table
      end

      def update(message)
        @table, cmd = @table.update(message)
        [self, cmd]
      end

      def rows=(positions)
        @positions = positions
        @table.rows = build_rows
      end

      def render
        label = Lipgloss::Style.new.bold(true).foreground("14").render("  Open Positions")
        count = Lipgloss::Style.new.foreground("240").render("  (#{@positions.size})")
        "#{label}#{count}\n#{@table.view}"
      end

      private

      def build_rows
        @positions.map do |pos|
          pnl = unrealized_pnl_for(pos)
          pnl_str = pnl ? format("%+.2f", pnl) : "N/A"
          [
            pos.id.to_s,
            pos.product_id.to_s[0, 18],
            pos.side.to_s,
            pos.entry_price&.round(2)&.to_s || "N/A",
            pos.size.to_s[0, 6],
            pos.day_trading? ? "Day" : "Swing",
            format_target(pos.take_profit),
            format_stop_loss(pos),
            pnl_str
          ]
        end
      end

      def format_target(value)
        value ? format("%.2f", value) : "—"
      end

      def format_stop_loss(position)
        return "—" unless position.stop_loss

        label = format("%.2f", position.stop_loss)
        position.trailing_stop_enabled? ? "#{label}T" : label
      end

      def unrealized_pnl_for(position)
        live_price = @live_prices[position.product_id]&.price
        return position.unrealized_pnl_at(live_price) if live_price

        position.pnl
      end

      def style_table
        @table.header_style = Lipgloss::Style.new.bold(true).foreground("240")
        @table.selected_style = Lipgloss::Style.new.bold(true).foreground("14")
      end
    end
  end
end
