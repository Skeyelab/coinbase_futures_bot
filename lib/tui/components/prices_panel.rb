# frozen_string_literal: true

require "lipgloss"

module Tui
  module Components
    class PricesPanel
      def initialize(futures_ticks, spot_ticks)
        @futures = futures_ticks
        @spot = spot_ticks
      end

      def render
        lines = []
        lines << render_section("Futures Prices", @futures)
        lines << render_section("Spot Prices", @spot)
        lines.join("\n")
      end

      # Section bodies without the inline title, for embedding in a PanelFrame
      # that already supplies the title (Market tab's futures/spot subpanels).
      def futures_body
        section_body(@futures)
      end

      def spot_body
        section_body(@spot)
      end

      private

      def render_section(title, ticks)
        label = Lipgloss::Style.new.bold(true).foreground("14").render("  #{title}")
        "#{label}\n#{section_body(ticks)}"
      end

      def section_body(ticks)
        if ticks.empty?
          "  #{Lipgloss::Style.new.foreground("240").render("no data")}"
        else
          rows = ticks.map do |tick|
            age = tick.observed_at ? (Time.now - tick.observed_at).to_i : nil
            age_str = if age.nil?
              "?"
            elsif age < 15
              "live"
            else
              "#{age}s ago"
            end
            price_style = (age && age < 15) ? Lipgloss::Style.new.foreground("10") : Lipgloss::Style.new.foreground("240")
            "  #{format("%-24s", tick.product_id)}  #{price_style.render(format("%12s", tick.price&.to_s || "N/A"))}  #{Lipgloss::Style.new.foreground("240").render(age_str)}"
          end
          rows.join("\n")
        end
      end
    end
  end
end
