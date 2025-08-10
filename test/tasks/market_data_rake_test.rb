require "test_helper"
require "rake"

class MarketDataRakeTest < ActiveJob::TestCase
  def setup
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  def test_subscribe_task_enqueues_job_with_args
    assert_enqueued_with(job: MarketDataSubscribeJob, args: [["BTC-USD-PERP", "ETH-USD-PERP"]]) do
      Rake::Task["market_data:subscribe"].reenable
      Rake::Task["market_data:subscribe"].invoke("BTC-USD-PERP,ETH-USD-PERP")
    end
  end

  def test_subscribe_task_uses_env_product_ids
    ENV["PRODUCT_IDS"] = "BTC-USD-PERP"
    begin
      assert_enqueued_with(job: MarketDataSubscribeJob, args: [["BTC-USD-PERP"]]) do
        Rake::Task["market_data:subscribe"].reenable
        Rake::Task["market_data:subscribe"].invoke(nil)
      end
    ensure
      ENV.delete("PRODUCT_IDS")
    end
  end
end