# frozen_string_literal: true

require "lipgloss"

module Tui
  module Components
    class HealthPanel
      def initialize(data:, rtm_status:)
        @data = data
        @rtm_status = rtm_status
      end

      def render
        lines = []
        lines << status_line("Real-time monitoring", monitoring_label)
        lines << detail_line("Futures feed", futures_feed_label)
        lines << detail_line("Spot feed", spot_feed_label)
        lines << detail_line("GoodJob RTM jobs", good_job_label)
        lines << detail_line("Latest futures tick", futures_tick_label)
        lines << detail_line("Last signal eval", eval_label)
        sentiment_section.each { |line| lines << line }
        lines << ""
        lines << operations_heading
        Tui::OperationsCatalog.entries.each do |entry|
          lines << operation_line(entry)
        end
        Lipgloss::Style.new.foreground("250").render(lines.join("\n"))
      end

      private

      def monitoring_label
        return "ON" if @rtm_status[:active]

        pending = @rtm_status[:good_job_pending].to_i
        return "pending (GoodJob x#{pending})" if pending.positive?

        "OFF"
      end

      def futures_feed_label
        ids = Array(@rtm_status[:futures_product_ids])
        return "—" unless @rtm_status[:active] && ids.any?

        ids.join(", ")
      end

      def spot_feed_label
        ids = Array(@rtm_status[:spot_product_ids])
        return "—" unless @rtm_status[:active] && ids.any?

        ids.join(", ")
      end

      def good_job_label
        count = @rtm_status[:good_job_pending].to_i
        count.positive? ? count.to_s : "none"
      end

      def futures_tick_label
        latest = @data[:latest_futures_tick_at]
        latest ? latest.strftime("%H:%M:%S") : "—"
      end

      def eval_label
        last_eval = @data[:last_eval_at]
        last_eval ? last_eval.strftime("%H:%M:%S") : "—"
      end

      # Sentiment health block: per-symbol z-scores, source enabled/disabled
      # status, enabled-contract count, and a stale marker. Rendered only when
      # the data loader supplied a Sentiment::Snapshot result.
      def sentiment_section
        snapshot = @data[:sentiment]
        return [] if snapshot.nil?

        lines = ["", sentiment_heading]
        if snapshot.symbols.empty?
          lines << detail_line("Sentiment", "no enabled symbols")
        else
          snapshot.symbols.each { |s| lines << sentiment_symbol_line(s) }
        end
        lines << detail_line("Sources", source_health_label(snapshot.sources))
        lines << detail_line("Enabled contracts", (@data[:enabled_contract_count] || 0).to_s)
        lines << stale_line if snapshot.stale?
        lines.compact
      end

      def sentiment_heading
        Lipgloss::Style.new.bold(true).foreground("14").render("  Sentiment")
      end

      def sentiment_symbol_line(sym)
        value = if sym.z_score.nil?
          "no data"
        else
          "z=#{format("%.1f", sym.z_score)} (#{sym.event_count}/#{sym.window})"
        end
        detail_line("  #{sym.symbol}", value)
      end

      def source_health_label(sources)
        return "—" if sources.blank?

        sources.map { |s| "#{s[:name]} #{s[:enabled] ? "✓" : "✗"}" }.join("  ")
      end

      def stale_line
        "  #{Lipgloss::Style.new.foreground("11").render("⚠ sentiment stale")}"
      end

      def status_line(label, value)
        color = (value == "ON") ? "10" : "240"
        "  #{label}: #{Lipgloss::Style.new.foreground(color).render(value)}"
      end

      def detail_line(label, value)
        "  #{label}: #{Lipgloss::Style.new.foreground("240").render(value)}"
      end

      def operations_heading
        Lipgloss::Style.new.bold(true).foreground("14").render("  Operations")
      end

      def operation_line(entry)
        key = Lipgloss::Style.new.foreground("11").render("[#{entry.key}]")
        label = Lipgloss::Style.new.foreground("250").render(entry.label)
        detail = Lipgloss::Style.new.foreground("238").render(" — #{entry.description}")
        "  #{key} #{label}#{detail}"
      end
    end
  end
end
