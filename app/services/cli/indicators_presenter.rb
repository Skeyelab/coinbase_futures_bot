# frozen_string_literal: true

module Cli
  # Renders OperatorSnapshot#indicators as a compact, plain-text block for the
  # human `bin/futuresbot status` (issue #436). No ANSI — the CLI adds framing.
  # The full 1/4/24h detail stays in `status --json`; this shows the 4h headline.
  module IndicatorsPresenter
    HEADLINE_HORIZON = "4"

    def self.lines(indicators)
      ind = indicators.with_indifferent_access
      predictiveness_lines(ind[:predictiveness]) + [protections_line(ind[:protections])]
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

    def self.num(value)
      value.nil? ? "n/a" : value.to_f.round(2).to_s
    end

    def self.pct(value)
      value.nil? ? "n/a" : "#{(value.to_f * 100).round}%"
    end

    private_class_method :predictiveness_lines, :protections_line, :num, :pct
  end
end
