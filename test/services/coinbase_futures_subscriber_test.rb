# frozen_string_literal: true

require "test_helper"
require "stringio"
require "ostruct"
require "logger"

class CoinbaseFuturesSubscriberTest < ActiveSupport::TestCase
  def build_logger(io)
    logger = Logger.new(io)
    logger.level = Logger::DEBUG
    logger
  end

  def test_handle_message_logs_ticker
    io = StringIO.new
    logger = build_logger(io)
    service = MarketData::CoinbaseFuturesSubscriber.new(product_ids: "BTC-USD-PERP", logger: logger)

    message = OpenStruct.new(data: { type: "ticker", product_id: "BTC-USD-PERP", price: "123.45", time: "2024-01-01T00:00:00Z" }.to_json)
    service.send(:handle_message, message)

    io.rewind
    assert_includes io.read, "[MD] ticker:"
  end

  def test_handle_message_logs_advanced_trade_ticker_schema
    io = StringIO.new
    logger = build_logger(io)
    service = MarketData::CoinbaseFuturesSubscriber.new(product_ids: "BTC-USD", logger: logger)

    payload = {
      channel: "ticker",
      events: [
        {
          type: "snapshot",
          tickers: [
            { product_id: "BTC-USD", price: "65000.00", time: "2024-01-01T00:00:00Z" }
          ]
        }
      ]
    }
    message = OpenStruct.new(data: payload.to_json)
    service.send(:handle_message, message)

    io.rewind
    assert_includes io.read, "[MD] ticker:"
  end

  def test_handle_message_ignores_non_json
    io = StringIO.new
    logger = build_logger(io)
    service = MarketData::CoinbaseFuturesSubscriber.new(product_ids: "BTC-USD-PERP", logger: logger)

    message = OpenStruct.new(data: "not json")
    service.send(:handle_message, message)

    io.rewind
    assert_equal "", io.read
  end
end
