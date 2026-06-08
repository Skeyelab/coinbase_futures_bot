# frozen_string_literal: true

class RealTimeMonitoringJob < ApplicationJob
  queue_as :critical

  def perform(product_ids: nil, futures_product_ids: nil, spot_product_ids: nil)
    result = RealtimeMonitoring::Session.new.run_blocking(
      product_ids: product_ids,
      futures_product_ids: futures_product_ids,
      spot_product_ids: spot_product_ids
    )

    Rails.logger.warn("[RTM] #{result[:error]}") unless result[:success]
  end
end
