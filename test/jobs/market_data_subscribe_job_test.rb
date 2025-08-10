require "test_helper"

class MarketDataSubscribeJobTest < ActiveJob::TestCase
  def test_perform_starts_subscriber_with_product_ids
    fake = Minitest::Mock.new
    fake.expect :start, nil

    stub_new = ->(**kwargs) do
      assert_equal ["BTC-USD-PERP"], kwargs[:product_ids]
      fake
    end

    MarketData::CoinbaseFuturesSubscriber.stub :new, stub_new do
      MarketDataSubscribeJob.perform_now(["BTC-USD-PERP"])
    end

    assert_mock fake
  end
end