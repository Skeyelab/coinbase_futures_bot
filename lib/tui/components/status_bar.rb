# frozen_string_literal: true

require "lipgloss"

module Tui
  module Components
    class StatusBar
      def initialize(data)
        @data = data
      end

      def render
        d = @data
        halt = d[:halt_active]
        eval_at = d[:last_eval_at]

        halt_label = if halt
          Lipgloss::Style.new.bold(true).foreground("9").render("  ⛔ TRADING HALTED")
        else
          Lipgloss::Style.new.foreground("10").render("  ✓ ACTIVE")
        end

        dim = Lipgloss::Style.new.foreground("240")

        parts = [
          halt_label,
          dim.render("Day: #{d[:day_pos_count] || 0}  Swing: #{d[:swing_pos_count] || 0}  Signals: #{d[:signal_count] || 0}"),
          dim.render("Eval: #{eval_label(eval_at)}")
        ]

        parts.join("  ")
      end

      private

      def eval_label(last_eval_at)
        return "never" unless last_eval_at

        age = (Time.now - last_eval_at).to_i
        if age < 120
          "#{age}s ago"
        else
          "#{age / 60}m ago"
        end
      end
    end
  end
end
