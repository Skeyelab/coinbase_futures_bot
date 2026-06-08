# frozen_string_literal: true

module Trading
  module PositionManagement
    class SwingRiskMonitoringWorkflow < BaseWorkflow
      WORKFLOW_NAME = "swing_risk_monitoring"

      def initialize(logger: Rails.logger, manager: nil, clock: -> { Time.current })
        super(logger: logger)
        @manager = manager || Trading::SwingPositionManager.new(logger: logger)
        @clock = clock
      end

      def call
        logger.info("Starting swing risk monitoring workflow")

        position_summary = @manager.get_swing_position_summary
        balance_summary = @manager.get_swing_balance_summary

        logger.info(
          "Swing position summary: #{position_summary[:total_positions]} positions, " \
          "Total exposure: $#{position_summary[:total_exposure].round(2)}, " \
          "Unrealized PnL: $#{position_summary[:unrealized_pnl].round(2)}"
        )

        if position_summary[:total_positions].to_i.zero?
          logger.info("No swing positions to monitor")
          return workflow_result(
            workflow: WORKFLOW_NAME,
            status: :noop,
            details: {total_positions: 0}
          )
        end

        monitor_balance(balance_summary)
        monitor_risk_metrics(position_summary[:risk_metrics] || {})
        send_periodic_summary(position_summary, balance_summary)

        workflow_result(
          workflow: WORKFLOW_NAME,
          status: :success,
          details: {
            total_positions: position_summary[:total_positions],
            total_exposure: position_summary[:total_exposure],
            balance_error: balance_summary[:error].present?
          }
        )
      end

      private

      def monitor_balance(balance_summary)
        if balance_summary[:error]
          logger.error("Failed to retrieve balance information: #{balance_summary[:error]}")
          return
        end

        margin_utilization = if balance_summary[:total_usd_balance].to_f.positive?
          balance_summary[:initial_margin].to_f / balance_summary[:total_usd_balance].to_f
        else
          0
        end

        logger.info(
          "Margin utilization: #{(margin_utilization * 100).round(2)}%, " \
          "Available margin: $#{balance_summary[:available_margin].round(2)}"
        )

        return unless margin_utilization > 0.8

        send_alert(
          "warning",
          "High Swing Trading Margin Utilization",
          "Swing trading margin utilization is #{(margin_utilization * 100).round(1)}%. " \
          "Available margin: $#{balance_summary[:available_margin].round(2)}"
        )
      end

      def monitor_risk_metrics(risk_metrics)
        if risk_metrics[:positions_approaching_expiry].to_i.positive?
          logger.warn("#{risk_metrics[:positions_approaching_expiry]} swing positions approaching contract expiry")
        end

        if risk_metrics[:positions_exceeding_max_hold].to_i.positive?
          logger.warn("#{risk_metrics[:positions_exceeding_max_hold]} swing positions exceeding maximum hold period")
        end

        max_asset_concentration = risk_metrics[:max_asset_concentration]
        if max_asset_concentration && max_asset_concentration > 0.6
          logger.warn("High asset concentration risk: #{(max_asset_concentration * 100).round(1)}%")
          send_alert(
            "info",
            "Swing Trading Asset Concentration Warning",
            "Asset concentration risk is #{(max_asset_concentration * 100).round(1)}%. " \
            "Consider diversifying swing positions across more assets."
          )
        end

        avg_hold_time_hours = risk_metrics[:avg_hold_time_hours]
        return unless avg_hold_time_hours && avg_hold_time_hours > 96

        logger.info("Average swing position hold time: #{avg_hold_time_hours.round(1)} hours")
      end

      def send_periodic_summary(position_summary, balance_summary)
        now = @clock.call.in_time_zone
        return unless now.hour.between?(9, 17) && now.wday.between?(1, 5)
        return unless now.hour == 10 && now.min < 30

        send_alert(
          "info",
          "Daily Swing Trading Summary",
          build_summary_text(position_summary, balance_summary)
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

        alerts = []
        risk_metrics = position_summary[:risk_metrics] || {}
        alerts << "#{risk_metrics[:positions_approaching_expiry]} approaching expiry" if risk_metrics[:positions_approaching_expiry].to_i.positive?
        alerts << "#{risk_metrics[:positions_exceeding_max_hold]} exceeding max hold" if risk_metrics[:positions_exceeding_max_hold].to_i.positive?

        max_asset_concentration = risk_metrics[:max_asset_concentration]
        if max_asset_concentration && max_asset_concentration > 0.5
          alerts << "High asset concentration (#{(max_asset_concentration * 100).round(1)}%)"
        end

        text += "\n⚠️ **Alerts**: #{alerts.join(", ")}" if alerts.any?
        text
      end
    end
  end
end
