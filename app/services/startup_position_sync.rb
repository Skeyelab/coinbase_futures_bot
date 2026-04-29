# frozen_string_literal: true

class StartupPositionSync
  Result = Struct.new(:status, :message, keyword_init: true)

  def initialize(import_service: PositionImportService.new, logger: Rails.logger, env: ENV)
    @import_service = import_service
    @logger = logger
    @env = env
  end

  def call
    return Result.new(status: :skipped) if skip?

    result = @import_service.import_positions_from_coinbase
    Result.new(status: :ok, message: success_message(result))
  rescue => e
    @logger.warn("[StartupPositionSync] #{e.message}")
    Result.new(status: :error, message: "Position sync skipped: #{e.message}")
  end

  private

  def skip?
    @env["FUTURESBOT_SKIP_POSITION_SYNC"].present?
  end

  def success_message(result)
    "Positions synced from Coinbase (#{result[:imported]} new, #{result[:updated]} updated, " \
      "#{result[:total_coinbase]} on exchange)"
  end
end
