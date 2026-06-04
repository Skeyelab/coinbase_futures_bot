# frozen_string_literal: true

module PositionManagement
  class SwingRiskMonitoringWorkflow
    include AlertPolicy

    MAX_HOLD_TIME_HOURS = 96
    SUMMARY_HOUR = 10
    SUMMARY_WINDOW_MINUTES = 30

    attr_reader :logger

    def initialize(manager: Trading::SwingPositionManager.new(logger: Rails.logger), logger: Rails.logger)
      @manager = manager
      @logger = logger
    end

    def call
      alerts = []
      metadata = {}

      logger.info("Starting swing risk monitoring workflow")

      position_summary = @manager.get_swing_position_summary
      balance_summary = @manager.get_swing_balance_summary

      logger.info("Swing position summary: #{position_summary[:total_positions]} positions, " \
                  "Total exposure: $#{position_summary[:total_exposure].round(2)}, " \
                  "Unrealized PnL: $#{position_summary[:unrealized_pnl].round(2)}")

      if position_summary[:total_positions] == 0
        logger.info("No swing positions to monitor")
        return WorkflowResult.new(
          workflow: "swing_risk_monitoring",
          status: :success,
          metadata: {total_positions: 0},
          alerts: alerts
        )
      end

      monitor_margin(balance_summary, alerts)
      monitor_risk_metrics(position_summary[:risk_metrics], alerts)

      send_periodic_summary(position_summary, balance_summary, alerts) if business_hours?

      metadata[:position_summary] = position_summary
      metadata[:balance_summary] = balance_summary
      logger.info("Swing risk monitoring workflow completed successfully")

      WorkflowResult.new(
        workflow: "swing_risk_monitoring",
        status: :success,
        metadata: metadata,
        alerts: alerts
      )
    rescue => e
      logger.error("Swing risk monitoring workflow failed: #{e.message}")
      logger.error(e.backtrace.join("\n"))

      Sentry.with_scope do |scope|
        scope.set_tag("workflow_type", "swing_risk_monitoring")
        scope.set_context("workflow_failure", {
          error_class: e.class.to_s,
          error_message: e.message
        })

        Sentry.capture_exception(e)
      end

      WorkflowResult.new(
        workflow: "swing_risk_monitoring",
        status: :failed,
        metadata: {},
        alerts: alerts,
        error: e.message
      )
    end

    private

    def monitor_margin(balance_summary, alerts)
      if balance_summary[:error]
        logger.error("Failed to retrieve balance information: #{balance_summary[:error]}")
        return
      end

      margin_utilization = if balance_summary[:total_usd_balance] > 0
        (balance_summary[:initial_margin] / balance_summary[:total_usd_balance])
      else
        0
      end

      logger.info("Margin utilization: #{(margin_utilization * 100).round(2)}%, " \
                  "Available margin: $#{balance_summary[:available_margin].round(2)}")

      return unless margin_utilization > 0.8

      notify(
        alerts,
        severity: "warning",
        title: "High Swing Trading Margin Utilization",
        message: "Swing trading margin utilization is #{(margin_utilization * 100).round(1)}%. " \
                 "Available margin: $#{balance_summary[:available_margin].round(2)}"
      )
    end

    def monitor_risk_metrics(risk_metrics, alerts)
      if risk_metrics[:positions_approaching_expiry] > 0
        logger.warn("#{risk_metrics[:positions_approaching_expiry]} swing positions approaching contract expiry")
      end

      if risk_metrics[:positions_exceeding_max_hold] > 0
        logger.warn("#{risk_metrics[:positions_exceeding_max_hold]} swing positions exceeding maximum hold period")
      end

      return unless risk_metrics[:max_asset_concentration] && risk_metrics[:max_asset_concentration] > 0.6

      logger.warn("High asset concentration risk: #{(risk_metrics[:max_asset_concentration] * 100).round(1)}%")
      notify(
        alerts,
        severity: "info",
        title: "Swing Trading Asset Concentration Warning",
        message: "Asset concentration risk is #{(risk_metrics[:max_asset_concentration] * 100).round(1)}%. " \
                 "Consider diversifying swing positions across more assets."
      )

      if risk_metrics[:avg_hold_time_hours] && risk_metrics[:avg_hold_time_hours] > MAX_HOLD_TIME_HOURS
        logger.info("Average swing position hold time: #{risk_metrics[:avg_hold_time_hours].round(1)} hours")
      end
    end

    def send_periodic_summary(position_summary, balance_summary, alerts)
      return if position_summary[:total_positions] == 0
      return unless Time.zone.now.hour == SUMMARY_HOUR && Time.zone.now.min < SUMMARY_WINDOW_MINUTES

      notify(
        alerts,
        severity: "info",
        title: "Daily Swing Trading Summary",
        message: build_summary_text(position_summary, balance_summary)
      )
    end

    def build_summary_text(position_summary, balance_summary)
      text = "📊 *Swing Trading Summary*\n\n"
      text += "• **Positions**: #{position_summary[:total_positions]}\n"
      text += "• **Total Exposure**: $#{position_summary[:total_exposure].round(2)}\n"
      text += "• **Unrealized PnL**: $#{position_summary[:unrealized_pnl].round(2)}\n"

      if balance_summary[:available_margin]
        text += "• **Available Margin**: $#{balance_summary[:available_margin].round(2)}\n"
      end

      if position_summary[:positions_by_asset]&.any?
        text += "\n**By Asset**:\n"
        position_summary[:positions_by_asset].each do |asset, data|
          text += "• #{asset}: #{data[:count]} positions, $#{data[:pnl].round(2)} PnL\n"
        end
      end

      risk_metrics = position_summary[:risk_metrics]
      summary_alerts = []
      summary_alerts << "#{risk_metrics[:positions_approaching_expiry]} approaching expiry" if risk_metrics[:positions_approaching_expiry] > 0
      summary_alerts << "#{risk_metrics[:positions_exceeding_max_hold]} exceeding max hold" if risk_metrics[:positions_exceeding_max_hold] > 0
      if risk_metrics[:max_asset_concentration] && risk_metrics[:max_asset_concentration] > 0.5
        summary_alerts << "High asset concentration (#{(risk_metrics[:max_asset_concentration] * 100).round(1)}%)"
      end

      text += "\n⚠️ **Alerts**: #{summary_alerts.join(", ")}" if summary_alerts.any?
      text
    end

    def business_hours?
      Time.current.hour.between?(9, 17) && Time.current.wday.between?(1, 5)
    end
  end
end
