# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::CoinbaseFuturesSubscriber do
  # Anonymous fake socket (no leaked constant): records the subscribe messages
  # sent and lets the test fire WebSocket events.
  let(:socket) do
    Class.new do
      def initialize
        @handlers = {}
        @sent = []
      end

      attr_reader :sent

      def on(event, &blk)
        @handlers[event] = blk
      end

      def fire(event, *args)
        @handlers[event]&.call(*args)
      end

      def send(msg)
        @sent << msg
      end

      def close = nil
    end.new
  end

  def message(payload)
    Struct.new(:data).new(payload.to_json)
  end

  it "subscribes on open and routes ticker messages to on_ticker (via the supervisor)" do
    ticks = []
    driver = nil
    subscriber = described_class.new(
      product_ids: ["BTC-USD"], on_ticker: ->(t) { ticks << t },
      enable_candle_aggregation: false,
      connect: ->(_url) { socket }, sleeper: ->(dt) { driver.call(dt) }
    )

    step = 0
    driver = lambda do |_dt|
      step += 1
      case step
      when 1
        socket.fire(:open)
        socket.fire(:message, message(
          channel: "ticker",
          events: [{tickers: [{product_id: "BTC-USD", price: "50000.5", time: "2026-07-24T00:00:00Z"}]}]
        ))
      when 2 then subscriber.stop
      end
    end

    subscriber.start

    expect(socket.sent.size).to eq(1) # subscribed exactly once on open
    expect(JSON.parse(socket.sent.first)).to include("channel" => "ticker", "product_ids" => ["BTC-USD"])
    expect(ticks).to eq([{"product_id" => "BTC-USD", "price" => "50000.5", "time" => "2026-07-24T00:00:00Z"}])
  end
end
