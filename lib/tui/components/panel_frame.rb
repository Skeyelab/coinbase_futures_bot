# frozen_string_literal: true

require "lipgloss"

module Tui
  module Components
    class PanelFrame
      def initialize(title:, count: nil, width: nil)
        @title = title
        @count = count
        @width = width
      end

      def render(content)
        header = title_style.render(@title)
        header += dim_style.render(" (#{@count})") unless @count.nil?
        bordered = frame_style.width(@width).render(content.to_s.strip)
        "#{header}\n#{bordered}"
      end

      private

      def title_style
        Lipgloss::Style.new.bold(true).foreground("14")
      end

      def dim_style
        Lipgloss::Style.new.foreground("240")
      end

      def frame_style
        Lipgloss::Style.new.border(lipgloss: true).border_foreground("240").padding(0, 1)
      end
    end
  end
end
