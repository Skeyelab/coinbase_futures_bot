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
          dry_run_label(d[:dry_run]),
          halt_label,
          dim.render("Day: #{d[:day_pos_count] || 0}  Swing: #{d[:swing_pos_count] || 0}  Signals: #{d[:signal_count] || 0}"),
          dim.render("Eval: #{eval_label(eval_at)}"),
          sentiment_part(d[:sentiment])
        ]

        parts.compact.join("  ")
      end

      private

      def dry_run_label(active)
        return nil unless active

        Lipgloss::Style.new.bold(true).foreground("11").render("  🧪 DRY-RUN")
      end

      def eval_label(last_eval_at)
        return "never" unless last_eval_at

        age = (Time.now - last_eval_at).to_i
        if age < 120
          "#{age}s ago"
        else
          "#{age / 60}m ago"
        end
      end

      # Renders a compact per-symbol summary (e.g. "OIL-USD z=-0.4 (3/15m)").
      # Stale pipelines are dimmed with a warning marker; symbols without an
      # aggregate yet are skipped so the strip stays terse.
      def sentiment_part(snapshot)
        return nil if snapshot.nil?

        summaries = snapshot.symbols.filter_map do |s|
          next if s.z_score.nil?

          "#{s.symbol} z=#{format("%.1f", s.z_score)} (#{s.event_count}/#{s.window})"
        end
        return nil if summaries.empty?

        text = summaries.join("  ")
        if snapshot.stale?
          Lipgloss::Style.new.foreground("11").render("⚠ #{text} (stale)")
        else
          Lipgloss::Style.new.foreground("240").render(text)
        end
      end
    end
  end
end
