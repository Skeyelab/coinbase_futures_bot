# frozen_string_literal: true

module Cli
  # Renders OperatorSnapshot#indicators as a compact, plain-text block for the
  # human `bin/futuresbot status` (issue #436). No ANSI — the CLI adds framing.
  # The full 1/4/24h detail stays in `status --json`; this shows the 4h headline.
  module IndicatorsPresenter
    HEADLINE_HORIZON = "4"

    def self.lines(indicators)
      ind = indicators.with_indifferent_access
      predictiveness_lines(ind[:predictiveness]) + sentiment_lines(ind[:sentiment]) +
        [protections_line(ind[:protections]), exits_line(ind[:exits])]
    end

    def self.sentiment_lines(sentiment)
      symbols = sentiment&.dig(:symbols) || []
      return [] if symbols.empty?

      ["  Sentiment:"] + symbols.map do |s|
        flag = s[:undersampled] ? " ⚠undersampled" : ""
        "    #{s[:symbol]} z=#{num(s[:z])} #{trend_arrow(s[:trend])} (#{s[:inflow_per_hr]}/hr)#{flag}"
      end
    end

    def self.trend_arrow(trend)
      return "→" if trend.nil? || trend.size < 2

      delta = trend.last.to_f - trend.first.to_f
      return "↑" if delta > 0.05
      return "↓" if delta < -0.05

      "→"
    end

    def self.predictiveness_lines(predictiveness)
      symbols = predictiveness&.dig(:symbols) || []
      return ["  predictiveness: not computed yet"] if symbols.empty?

      symbols.map do |s|
        h = s.dig(:horizons, HEADLINE_HORIZON) || {}
        "  #{s[:sentiment_symbol]} → #{s[:price_symbol]}  4h: " \
          "r=#{num(h[:correlation])} hit=#{pct(h[:hit_rate])} n=#{h[:n] || 0} [#{s[:maturity]}]"
      end
    end

    def self.protections_line(protections)
      active = protections&.dig(:active) || []
      summary = if active.empty?
        "none"
      else
        "#{active.size} active (#{active.filter_map { |l| l[:source] }.uniq.join(", ")})"
      end
      dd = protections&.dig(:drawdown, :drawdown_pct)
      line = "  Protections: #{summary}"
      line += " | drawdown #{dd}%" if dd
      line
    end

    def self.exits_line(exits)
      dollar = exits&.dig(:dollar_exit) || {}
      symbols = exits&.dig(:symbols) || []
      liq_on = symbols.count { |s| s.dig(:liquidation_buffer, :enabled) }
      roi_on = symbols.count { |s| s.dig(:min_roi, :enabled) }
      dollar_desc = dollar[:enabled] ? "tgt=#{usd(dollar[:profit_target])}/sl=#{usd(dollar[:stop_loss])}" : "off"
      "  Exits: dollar #{dollar_desc} | liq-buffer #{liq_on}/#{symbols.size} | min-roi #{roi_on}/#{symbols.size}"
    end

    def self.usd(value)
      value.nil? ? "off" : "$#{value.to_f.round(2)}"
    end

    def self.num(value)
      value.nil? ? "n/a" : value.to_f.round(2).to_s
    end

    def self.pct(value)
      value.nil? ? "n/a" : "#{(value.to_f * 100).round}%"
    end

    private_class_method :predictiveness_lines, :sentiment_lines, :trend_arrow, :protections_line, :exits_line, :usd, :num, :pct
  end
end
