# frozen_string_literal: true

require "gum"

module Tui
  module Forms
    class EditPositionTarget
      FIELD_LABELS = {
        take_profit: "take-profit",
        stop_loss: "stop-loss"
      }.freeze

      def self.run(field:, id_str:)
        new(field: field, id_str: id_str).run
      end

      def initialize(field:, id_str:)
        @field = field.to_sym
        @id_str = id_str.to_s.strip
      end

      def run
        return unless valid_field?
        return unless valid_id?

        position = Position.find_by(id: @id_str.to_i, status: "OPEN")
        unless position
          Gum.log("No OPEN position ##{@id_str}", level: "error")
          return
        end

        show_context(position)
        warn_trailing_stop(position) if @field == :stop_loss

        raw_price = Gum.input(
          header: "New #{FIELD_LABELS.fetch(@field)} for ##{position.id}",
          placeholder: "Price (blank=cancel)"
        )
        return if raw_price.to_s.strip.empty?

        confirmed = Gum.confirm(
          "Set #{FIELD_LABELS.fetch(@field)} to #{raw_price} for #{position.product_id} ##{position.id}?",
          affirmative: "Save",
          negative: "Cancel"
        )
        return unless confirmed

        result = Trading::PositionTargetUpdater.call(:position => position, @field => raw_price)
        if result[:success]
          Gum.log("#{FIELD_LABELS.fetch(@field).capitalize} updated (local DB only; no exchange order)", level: "info")
        else
          Gum.log("Update failed: #{result[:error]}", level: "error")
        end
      rescue => e
        Gum.log("Target edit error: #{e.message}", level: "error")
      end

      private

      def valid_field?
        return true if FIELD_LABELS.key?(@field)

        Gum.log("Unknown target field: #{@field}", level: "error")
        false
      end

      def valid_id?
        return true if @id_str.match?(/\A\d+\z/)

        Gum.log("Invalid position id: #{@id_str}", level: "error")
        false
      end

      def show_context(position)
        current = position.public_send(@field)
        current_label = current ? format("%.2f", current) : "unset"
        mark = position.get_current_market_price
        mark_label = mark ? format("%.2f", mark) : "N/A"
        Gum.log(
          "##{position.id} #{position.product_id} #{position.side} entry #{position.entry_price} mark #{mark_label} " \
          "current #{FIELD_LABELS.fetch(@field)} #{current_label}",
          level: "info"
        )
      end

      def warn_trailing_stop(position)
        return unless position.trailing_stop_enabled?

        Gum.log(
          "Trailing stop enabled — bot may overwrite manual stop-loss on next tick",
          level: "warn"
        )
      end
    end
  end
end
