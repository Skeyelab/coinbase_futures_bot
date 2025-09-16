# frozen_string_literal: true

class SwingRiskMonitoringJob < ApplicationJob
  queue_as :default

  def perform
    @logger = Rails.logger
    @manager = Trading::SwingPositionManager.new(logger: @logger)

    @logger.info("Starting swing risk monitoring job")

    # Get comprehensive position summary
    position_summary = @manager.get_swing_position_summary
    balance_summary = @manager.get_swing_balance_summary

    # Log current swing trading status
    @logger.info("Swing position summary: #{position_summary[:total_positions]} positions, " \
                "Total exposure: $#{position_summary[:total_exposure].round(2)}, " \
                "Unrealized PnL: $#{position_summary[:unrealized_pnl].round(2)}")

    # Check if there are any positions to monitor
    if position_summary[:total_positions] == 0
      @logger.info("No swing positions to monitor")
      return
    end

    # Monitor balance and margin health
    if balance_summary[:error]
      @logger.error("Failed to retrieve balance information: #{balance_summary[:error]}")
    else
      margin_utilization = (balance_summary[:total_usd_balance] > 0) ?
        (balance_summary[:initial_margin] / balance_summary[:total_usd_balance]) : 0

      @logger.info("Margin utilization: #{(margin_utilization * 100).round(2)}%, " \
                  "Available margin: $#{balance_summary[:available_margin].round(2)}")

      # Alert if margin utilization is high
      if margin_utilization > 0.8
        SlackNotificationService.alert(
          "warning",
          "High Swing Trading Margin Utilization",
          "Swing trading margin utilization is #{(margin_utilization * 100).round(1)}%. " \
          "Available margin: $#{balance_summary[:available_margin].round(2)}"
        )
      end
    end

    # Monitor positions approaching risk thresholds
    risk_metrics = position_summary[:risk_metrics]

    if risk_metrics[:positions_approaching_expiry] > 0
      @logger.warn("#{risk_metrics[:positions_approaching_expiry]} swing positions approaching contract expiry")
    end

    if risk_metrics[:positions_exceeding_max_hold] > 0
      @logger.warn("#{risk_metrics[:positions_exceeding_max_hold]} swing positions exceeding maximum hold period")
    end

    # Monitor asset concentration risk
    if risk_metrics[:max_asset_concentration] && risk_metrics[:max_asset_concentration] > 0.6
      @logger.warn("High asset concentration risk: #{(risk_metrics[:max_asset_concentration] * 100).round(1)}%")

      SlackNotificationService.alert(
        "info",
        "Swing Trading Asset Concentration Warning",
        "Asset concentration risk is #{(risk_metrics[:max_asset_concentration] * 100).round(1)}%. " \
        "Consider diversifying swing positions across more assets."
      )
    end

    # Monitor average holding time
    if risk_metrics[:avg_hold_time_hours] && risk_metrics[:avg_hold_time_hours] > 96 # 4 days
      @logger.info("Average swing position hold time: #{risk_metrics[:avg_hold_time_hours].round(1)} hours")
    end

    # Send periodic summary to Slack (only during business hours to avoid spam)
    if Time.current.hour.between?(9, 17) && Time.current.wday.between?(1, 5)
      send_periodic_summary(position_summary, balance_summary)
    end

    @logger.info("Swing risk monitoring job completed successfully")
  rescue => e
    @logger.error("Swing risk monitoring job failed: #{e.message}")
    @logger.error(e.backtrace.join("\n"))

    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "swing_risk_monitoring")
      scope.set_context("job_failure", {
        error_class: e.class.to_s,
        error_message: e.message
      })

      Sentry.capture_exception(e)
    end

    # Don't re-raise for monitoring jobs - they should not fail the queue
  end

  private

  def send_periodic_summary(position_summary, balance_summary)
    return if position_summary[:total_positions] == 0

    # Only send summary once per day at 10 AM
    return unless Time.zone.now.hour == 10 && Time.zone.now.min < 30

    summary_text = build_summary_text(position_summary, balance_summary)

    SlackNotificationService.alert(
      "info",
      "Daily Swing Trading Summary",
      summary_text
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

    # Asset breakdown
    if position_summary[:positions_by_asset].any?
      text += "\n**By Asset**:\n"
      position_summary[:positions_by_asset].each do |asset, data|
        text += "• #{asset}: #{data[:count]} positions, $#{data[:pnl].round(2)} PnL\n"
      end
    end

    # Risk alerts
    risk_metrics = position_summary[:risk_metrics]
    alerts = []

    alerts << "#{risk_metrics[:positions_approaching_expiry]} approaching expiry" if risk_metrics[:positions_approaching_expiry] > 0
    alerts << "#{risk_metrics[:positions_exceeding_max_hold]} exceeding max hold" if risk_metrics[:positions_exceeding_max_hold] > 0
    alerts << "High asset concentration (#{(risk_metrics[:max_asset_concentration] * 100).round(1)}%)" if risk_metrics[:max_asset_concentration] && risk_metrics[:max_asset_concentration] > 0.5

    if alerts.any?
      text += "\n⚠️ **Alerts**: #{alerts.join(", ")}"
    end

    text
  end
end
