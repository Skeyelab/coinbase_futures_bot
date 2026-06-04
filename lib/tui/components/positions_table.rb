# frozen_string_literal: true

require "bubbles"
require "lipgloss"

module Tui
  module Components
    class PositionsTable
      COLUMNS = [
        {title: "ID", width: 6},
        {title: "Product", width: 22},
        {title: "Side", width: 6},
        {title: "Entry", width: 11},
        {title: "Size", width: 8},
        {title: "Type", width: 5},
        {title: "U.PnL", width: 12}
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
          live_price = @live_prices[pos.product_id]&.price
          pnl = pos.pnl || (live_price ? pos.calculate_pnl(live_price) : nil)
          pnl_str = pnl ? format("%+.2f", pnl) : "N/A"
          [
            pos.id.to_s,
            pos.product_id.to_s[0, 22],
            pos.side.to_s,
            pos.entry_price&.round(2)&.to_s || "N/A",
            pos.size.to_s[0, 8],
            pos.day_trading? ? "Day" : "Swing",
            pnl_str
          ]
        end
      end

      def style_table
        @table.header_style = Lipgloss::Style.new.bold(true).foreground("240")
        @table.selected_style = Lipgloss::Style.new.bold(true).foreground("14")
      end
    end
  end
end
