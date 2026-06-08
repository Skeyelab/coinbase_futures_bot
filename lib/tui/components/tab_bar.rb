# frozen_string_literal: true

require "lipgloss"

module Tui
  module Components
    class TabBar
      LABELS = {
        overview: "Overview",
        positions: "Positions",
        signals: "Signals",
        market: "Market",
        health: "Ops"
      }.freeze

      def initialize(layout)
        @layout = layout
      end

      def render
        segments = Tui::Layout::TABS.map.with_index(1) do |tab, number|
          label = "#{number} #{LABELS[tab]}"
          if tab == @layout.active_tab
            active_style.render(label)
          else
            dim_style.render(label)
          end
        end
        "  #{segments.join("  ")}"
      end

      private

      def active_style
        Lipgloss::Style.new.bold(true).foreground("14").background("236").padding(0, 1)
      end

      def dim_style
        Lipgloss::Style.new.foreground("240")
      end
    end
  end
end
