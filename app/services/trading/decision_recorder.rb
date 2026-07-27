# frozen_string_literal: true

module Trading
  # Writes SignalDecision rows (issue #480).
  #
  # Kept out of the job so recording can never take the trading path down: a
  # ledger write that raises must not prevent an order, and must not turn a
  # successful order into a logged failure. Everything here is best-effort and
  # failures are logged, never raised.
  class DecisionRecorder
    def initialize(product_id:, asset: nil, contract_id: nil, logger: Rails.logger)
      @product_id = product_id
      @asset = asset
      @contract_id = contract_id
      @logger = logger
    end

    attr_writer :contract_id

    def rejected(reason, signal: nil, **context)
      record(SignalDecision::REJECTED, reason, signal: signal, context: context)
    end

    def traded(signal: nil, position_id: nil, **context)
      record(SignalDecision::TRADED, "traded", signal: signal, position_id: position_id, context: context)
    end

    private

    def record(disposition, reason, signal: nil, position_id: nil, context: {})
      SignalDecision.create!(
        product_id: @product_id,
        contract_id: @contract_id,
        asset: @asset,
        disposition: disposition,
        reason: reason.to_s,
        side: signal && signal[:side].to_s.presence,
        confidence: signal && signal[:confidence],
        quantity: signal && signal[:quantity],
        position_id: position_id,
        context: context.compact,
        evaluated_at: Time.current
      )
    rescue => e
      @logger.error("[DecisionRecorder] failed to record #{reason}: #{e.message}")
      nil
    end
  end
end
