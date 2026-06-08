# frozen_string_literal: true

module Trading
  module PositionManagement
    WorkflowResult = Struct.new(:workflow, :status, :summary, :details, keyword_init: true) do
      def success?
        %i[success noop].include?(status)
      end

      def noop?
        status == :noop
      end
    end
  end
end
