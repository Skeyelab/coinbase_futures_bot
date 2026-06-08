# frozen_string_literal: true

module Trading
  class PositionTargetUpdater
    include SentryServiceTracking

    def self.call(position:, logger: Rails.logger, **targets)
      new(position: position, logger: logger, targets: targets).call
    end

    def initialize(position:, logger: Rails.logger, targets: {})
      @position = position
      @logger = logger
      @targets = targets.slice(:take_profit, :stop_loss).compact
    end

    def call
      return failure("Position must be OPEN") unless @position.open?

      updates = {}
      @targets.each do |field, value|
        price, error = validate_price(field, value)
        return failure(error) if error

        updates[field] = price
      end

      return failure("No target fields provided") if updates.empty?

      ordering_error = validate_ordering(updates)
      return ordering_error if ordering_error

      previous = updates.keys.index_with { |field| @position.public_send(field) }
      @position.update!(updates)
      log_update(previous, updates)

      {success: true, position: @position.reload}
    rescue ActiveRecord::RecordInvalid => e
      failure(e.message)
    end

    private

    def validate_price(field, value)
      price = BigDecimal(value.to_s)
      return [nil, "#{field_label(field)} must be positive"] unless price.positive?

      entry = BigDecimal(@position.entry_price.to_s)
      if @position.side == "LONG"
        if field == :take_profit && price <= entry
          return [nil, "LONG take-profit must be above entry price"]
        end
        if field == :stop_loss && price >= entry
          return [nil, "LONG stop-loss must be below entry price"]
        end
      elsif field == :take_profit && price >= entry
        return [nil, "SHORT take-profit must be below entry price"]
      elsif field == :stop_loss && price <= entry
        return [nil, "SHORT stop-loss must be above entry price"]
      end

      [price.to_f, nil]
    end

    def validate_ordering(updates)
      return nil unless updates.key?(:take_profit) && updates.key?(:stop_loss)

      entry = BigDecimal(@position.entry_price.to_s)
      tp = BigDecimal(updates[:take_profit].to_s)
      sl = BigDecimal(updates[:stop_loss].to_s)

      valid = if @position.side == "LONG"
        sl < entry && entry < tp
      else
        tp < entry && entry < sl
      end

      return nil if valid

      failure("Targets must bracket entry price for #{@position.side} positions")
    end

    def log_update(previous, updates)
      updates.each do |field, new_value|
        @logger.info(
          "[PositionTargetUpdater] #{@position.product_id} ##{@position.id} " \
          "#{field} #{previous[field].inspect} -> #{new_value}"
        )
      end

      SentryHelper.add_breadcrumb(
        message: "Position targets updated",
        category: "trading",
        level: "info",
        data: {
          position_id: @position.id,
          product_id: @position.product_id,
          fields: updates.keys
        }
      )
    end

    def field_label(field)
      field.to_s.tr("_", "-")
    end

    def failure(message)
      {success: false, error: message}
    end
  end
end
