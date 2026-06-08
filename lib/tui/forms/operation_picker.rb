# frozen_string_literal: true

require "gum"

module Tui
  module Forms
    class OperationPicker
      def self.run(active_tab:)
        choices = Tui::OperationsCatalog.for_tab(active_tab).reject { |entry| entry.key == "?" }
        return nil if choices.empty?

        labels = choices.map { |entry| "[#{entry.key}] #{entry.label}" }
        selected = Gum.choose(labels, header: "Select operation", height: [labels.size + 2, 12].min)
        return nil if selected.to_s.strip.empty?

        selected[/\[([a-z?])\]/i, 1]&.downcase
      end
    end
  end
end
