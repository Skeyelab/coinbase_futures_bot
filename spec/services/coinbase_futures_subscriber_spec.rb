# frozen_string_literal: true

require "rails_helper"
require "stringio"
require "ostruct"
require "logger"

RSpec.describe MarketData::CoinbaseFuturesSubscriber, type: :service do
  def build_logger(io)
    logger = Logger.new(io)
    logger.level = Logger::DEBUG
    logger
  end

  it "logs ticker messages" do
    io = StringIO.new
    logger = build_logger(io)
    service = described_class.new(product_ids: "BTC-USD-PERP", logger: logger)

    message = OpenStruct.new(data: {type: "ticker", product_id: "BTC-USD-PERP", price: "123.45", time: "2024-01-01T00:00:00Z"}.to_json)
    service.send(:handle_message, message)

    io.rewind
    expect(io.read).to include("[MD] ticker:")
  end

  it "logs advanced trade ticker schema" do
    io = StringIO.new
    logger = build_logger(io)
    service = described_class.new(product_ids: "BTC-USD", logger: logger)

    payload = {
      channel: "ticker",
      events: [
        {
          type: "snapshot",
          tickers: [{product_id: "BTC-USD", price: "65000.00", time: "2024-01-01T00:00:00Z"}]
        }
      ]
    }

    message = OpenStruct.new(data: payload.to_json)
    service.send(:handle_message, message)

    io.rewind
    expect(io.read).to include("[MD] ticker:")
  end

  it "ignores non-json messages" do
    io = StringIO.new
    logger = build_logger(io)
    service = described_class.new(product_ids: "BTC-USD-PERP", logger: logger)

    message = OpenStruct.new(data: "not json")
    service.send(:handle_message, message)

    io.rewind
    expect(io.read).to eq("")
  end
end
