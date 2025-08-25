# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "day_trading:check_positions", type: :task do
  let(:task) { Rake::Task["day_trading:check_positions"] }
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }

  before do
    Rake.application.rake_require "tasks/day_trading"
    Rake::Task.define_task(:environment)
    allow(Trading::DayTradingPositionManager).to receive(:new).and_return(manager)
  end

  it "displays summary of day trading positions" do
    summary = {
      open_count: 3,
      closed_today_count: 2,
      total_open_value: 150.0,
      total_pnl: 150.0,
      positions_needing_closure: 1,
      positions_approaching_closure: 0
    }
    allow(manager).to receive(:get_position_summary).and_return(summary)

    expect { task.execute }.to output(/Open positions: 3/).to_stdout
    expect { task.execute }.to output(/Closed today: 2/).to_stdout
    expect { task.execute }.to output(/Total open value: 150\.0/).to_stdout
    expect { task.execute }.to output(/Total PnL: 150\.0/).to_stdout
    expect { task.execute }.to output(/Positions needing closure: 1/).to_stdout
    expect { task.execute }.to output(/Positions approaching closure: 0/).to_stdout
  end

  it "handles empty positions gracefully" do
    summary = {
      open_count: 0,
      closed_today_count: 0,
      total_open_value: 0,
      total_pnl: 0,
      positions_needing_closure: 0,
      positions_approaching_closure: 0
    }
    allow(manager).to receive(:get_position_summary).and_return(summary)

    expect { task.execute }.to output(/Open positions: 0/).to_stdout
    expect { task.execute }.to output(/Closed today: 0/).to_stdout
  end
end

RSpec.describe "day_trading:close_expired", type: :task do
  let(:task) { Rake::Task["day_trading:close_expired"] }
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }

  before do
    Rake.application.rake_require "tasks/day_trading"
    Rake::Task.define_task(:environment)
    allow(Trading::DayTradingPositionManager).to receive(:new).and_return(manager)
  end

  it "closes expired positions and shows count" do
    allow(manager).to receive(:positions_need_closure?).and_return(true)
    allow(manager).to receive(:close_expired_positions).and_return(2)

    expect { task.execute }.to output(/✅ Closed 2 expired positions/).to_stdout
  end

  it "handles no expired positions" do
    allow(manager).to receive(:positions_need_closure?).and_return(false)
    allow(manager).to receive(:close_expired_positions).and_return(0)

    expect { task.execute }.to output(/No expired positions to close/).to_stdout
  end
end

RSpec.describe "day_trading:force_close_all", type: :task do
  let(:task) { Rake::Task["day_trading:force_close_all"] }
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }

  before do
    Rake.application.rake_require "tasks/day_trading"
    Rake::Task.define_task(:environment)
    allow(Trading::DayTradingPositionManager).to receive(:new).and_return(manager)
  end

  it "shows confirmation prompt and closes positions when confirmed" do
    summary = {open_count: 3}
    allow(manager).to receive(:get_position_summary).and_return(summary)
    allow(manager).to receive(:force_close_all_day_trading_positions).and_return(3)

    # Mock user input
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:gets).and_return("yes\n")

    expect { task.execute }.to output(/⚠️  Force closing all 3 day trading positions/).to_stdout
    expect { task.execute }.to output(/✅ Force closed 3 day trading positions/).to_stdout
  end

  it "cancels operation when user doesn't confirm" do
    summary = {open_count: 2}
    allow(manager).to receive(:get_position_summary).and_return(summary)
    allow(manager).to receive(:force_close_all_day_trading_positions).and_return(0)

    # Mock user input
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:gets).and_return("no\n")

    expect { task.execute }.to output(/❌ Operation cancelled/).to_stdout
  end

  it "handles non-interactive environment gracefully" do
    summary = {open_count: 2}
    allow(manager).to receive(:get_position_summary).and_return(summary)
    allow($stdin).to receive(:tty?).and_return(false)

    expect { task.execute }.to output(/⚠️  Non-interactive environment detected/).to_stdout
    expect { task.execute }.to output(/Set FORCE=true to run without confirmation/).to_stdout
  end

  it "forces close when FORCE environment variable is set" do
    ENV["FORCE"] = "true"

    summary = {open_count: 2}
    allow(manager).to receive(:get_position_summary).and_return(summary)
    allow(manager).to receive(:force_close_all_day_trading_positions).and_return(2)

    expect { task.execute }.to output(/Force mode enabled - proceeding without confirmation/).to_stdout
    expect { task.execute }.to output(/✅ Force closed 2 day trading positions/).to_stdout

    ENV.delete("FORCE")
  end

  it "shows no positions message when no open positions exist" do
    summary = {open_count: 0}
    allow(manager).to receive(:get_position_summary).and_return(summary)

    expect { task.execute }.to output(/✅ No open day trading positions to close/).to_stdout
  end
end

RSpec.describe "day_trading:check_tp_sl", type: :task do
  let(:task) { Rake::Task["day_trading:check_tp_sl"] }
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }

  before do
    Rake.application.rake_require "tasks/day_trading"
    Rake::Task.define_task(:environment)
    allow(Trading::DayTradingPositionManager).to receive(:new).and_return(manager)
  end

  it "shows TP/SL triggers and closes positions when confirmed" do
    position = instance_double(Position, id: 1, side: "LONG", size: 1.0, product_id: "BIT-29AUG25-CDE")
    trigger_info = {
      position: position,
      trigger: "take_profit",
      current_price: 51_000.0,
      target_price: 50_000.0
    }

    allow(manager).to receive(:check_tp_sl_triggers).and_return([trigger_info])
    allow(manager).to receive(:close_tp_sl_positions).and_return(1)

    # Mock user input
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:gets).and_return("yes\n")

    expect { task.execute }.to output(%r{Found 1 positions with triggered TP/SL}).to_stdout
    expect { task.execute }.to output(/Position 1: LONG 1\.0 BIT-29AUG25-CDE/).to_stdout
    expect { task.execute }.to output(%r{✅ Closed 1 TP/SL positions}).to_stdout
  end

  it "shows no triggers message when none exist" do
    allow(manager).to receive(:check_tp_sl_triggers).and_return([])

    expect { task.execute }.to output(%r{✅ No TP/SL triggers found}).to_stdout
  end

  it "cancels operation when user doesn't confirm" do
    position = instance_double(Position, id: 1, side: "LONG", size: 1.0, product_id: "BIT-29AUG25-CDE")
    trigger_info = {position: position, trigger: "take_profit", current_price: 51_000.0, target_price: 50_000.0}

    allow(manager).to receive(:check_tp_sl_triggers).and_return([trigger_info])
    allow(manager).to receive(:close_tp_sl_positions).and_return(0)

    # Mock user input
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:gets).and_return("no\n")

    expect { task.execute }.to output(/❌ Operation cancelled/).to_stdout
  end

  it "handles non-interactive environment gracefully" do
    position = instance_double(Position, id: 1, side: "LONG", size: 1.0, product_id: "BIT-29AUG25-CDE")
    trigger_info = {position: position, trigger: "take_profit", current_price: 51_000.0, target_price: 50_000.0}

    allow(manager).to receive(:check_tp_sl_triggers).and_return([trigger_info])
    allow($stdin).to receive(:tty?).and_return(false)

    expect { task.execute }.to output(/⚠️  Non-interactive environment detected/).to_stdout
    expect { task.execute }.to output(/Set FORCE=true to run without confirmation/).to_stdout
  end

  it "forces close when FORCE environment variable is set" do
    ENV["FORCE"] = "true"

    position = instance_double(Position, id: 1, side: "LONG", size: 1.0, product_id: "BIT-29AUG25-CDE")
    trigger_info = {position: position, trigger: "take_profit", current_price: 51_000.0, target_price: 50_000.0}

    allow(manager).to receive(:check_tp_sl_triggers).and_return([trigger_info])
    allow(manager).to receive(:close_tp_sl_positions).and_return(1)

    expect do
      task.execute
    end.to output(/Force mode enabled - proceeding to close positions without confirmation/).to_stdout
    expect { task.execute }.to output(%r{✅ Closed 1 TP/SL positions}).to_stdout

    ENV.delete("FORCE")
  end
end

RSpec.describe "day_trading:pnl", type: :task do
  let(:task) { Rake::Task["day_trading:pnl"] }
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }

  before do
    Rake.application.rake_require "tasks/day_trading"
    Rake::Task.define_task(:environment)
    allow(Trading::DayTradingPositionManager).to receive(:new).and_return(manager)
  end

  it "displays total PnL and individual position PnL" do
    position1 = instance_double(Position, product_id: "BIT-29AUG25-CDE", side: "LONG", size: 1.0)
    position2 = instance_double(Position, product_id: "ET-29AUG25-CDE", side: "SHORT", size: 2.0)

    allow(manager).to receive(:calculate_total_pnl).and_return(250.0)
    allow(Position).to receive(:open_day_trading_positions).and_return([position1, position2])
    allow(manager).to receive(:get_current_prices).and_return({
      1 => 51_000.0,
      2 => 2900.0
    })
    allow(position1).to receive(:id).and_return(1)
    allow(position2).to receive(:id).and_return(2)
    allow(position1).to receive(:calculate_pnl).with(51_000.0).and_return(100.0)
    allow(position2).to receive(:calculate_pnl).with(2900.0).and_return(150.0)

    expect { task.execute }.to output(/Current PnL for open day trading positions: 250\.0/).to_stdout
    expect { task.execute }.to output(/BIT-29AUG25-CDE: LONG 1\.0 - PnL: 100\.0/).to_stdout
    expect { task.execute }.to output(/ET-29AUG25-CDE: SHORT 2\.0 - PnL: 150\.0/).to_stdout
  end

  it "handles positions without price data" do
    position = instance_double(Position, product_id: "BIT-29AUG25-CDE", side: "LONG", size: 1.0)

    allow(manager).to receive(:calculate_total_pnl).and_return(0.0)
    allow(Position).to receive(:open_day_trading_positions).and_return([position])
    allow(manager).to receive(:get_current_prices).and_return({})
    allow(position).to receive(:id).and_return(1)

    expect { task.execute }.to output(/BIT-29AUG25-CDE: LONG 1\.0 - PnL: unknown \(no price data\)/).to_stdout
  end
end

RSpec.describe "day_trading:cleanup", type: :task do
  let(:task) { Rake::Task["day_trading:cleanup"] }

  before do
    Rake.application.rake_require "tasks/day_trading"
    Rake::Task.define_task(:environment)
  end

  it "cleans up old positions with default 30 days" do
    # Mock the count query to return 5 old positions
    allow(Position).to receive(:closed).and_return(
      double(where: double(count: 5))
    )
    allow(Position).to receive(:cleanup_old_positions).and_return(5)
    # Mock interactive behavior for both task.execute calls
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:gets).and_return("no\n")

    expect { task.execute }.to output(/Cleaning up closed positions older than 30 days/).to_stdout
    expect { task.execute }.to output(/Delete 5 old positions\? Type 'yes' to confirm/).to_stdout
  end

  it "cleans up old positions with custom days from environment" do
    ENV["DAYS_OLD"] = "60"

    # Mock the count query to return 5 old positions
    allow(Position).to receive(:closed).and_return(
      double(where: double(count: 5))
    )
    allow(Position).to receive(:cleanup_old_positions).and_return(5)
    # Mock interactive behavior for both task.execute calls
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:gets).and_return("no\n")

    expect { task.execute }.to output(/Cleaning up closed positions older than 60 days/).to_stdout

    ENV.delete("DAYS_OLD")
  end

  it "deletes positions when user confirms" do
    # Mock the count query to return 5 old positions
    allow(Position).to receive(:closed).and_return(
      double(where: double(count: 5))
    )
    allow(Position).to receive(:cleanup_old_positions).and_return(5)
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:gets).and_return("yes\n")

    expect { task.execute }.to output(/✅ Cleaned up 5 old positions/).to_stdout
  end

  it "cancels operation when user doesn't confirm" do
    # Mock the count query to return 5 old positions
    allow(Position).to receive(:closed).and_return(
      double(where: double(count: 5))
    )
    allow(Position).to receive(:cleanup_old_positions).and_return(5)
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:gets).and_return("no\n")

    expect { task.execute }.to output(/❌ Operation cancelled/).to_stdout
  end

  it "handles non-interactive environment gracefully" do
    # Mock the count query to return 5 old positions
    allow(Position).to receive(:closed).and_return(
      double(where: double(count: 5))
    )
    allow($stdin).to receive(:tty?).and_return(false)

    expect { task.execute }.to output(/⚠️  Non-interactive environment detected/).to_stdout
    expect { task.execute }.to output(/Set FORCE=true to run without confirmation/).to_stdout
  end

  it "forces cleanup when FORCE environment variable is set" do
    ENV["FORCE"] = "true"

    # Mock the count query to return 5 old positions
    allow(Position).to receive(:closed).and_return(
      double(where: double(count: 5))
    )
    allow(Position).to receive(:cleanup_old_positions).and_return(5)

    expect { task.execute }.to output(/Force mode enabled - proceeding without confirmation/).to_stdout
    expect { task.execute }.to output(/✅ Cleaned up 5 old positions/).to_stdout

    ENV.delete("FORCE")
  end

  it "shows no cleanup needed message when no old positions exist" do
    # Mock the count query to return 0 old positions
    allow(Position).to receive(:closed).and_return(
      double(where: double(count: 0))
    )

    expect { task.execute }.to output(/✅ No old positions to clean up/).to_stdout
  end
end

RSpec.describe "day_trading:details", type: :task do
  let(:task) { Rake::Task["day_trading:details"] }

  before do
    Rake.application.rake_require "tasks/day_trading"
    Rake::Task.define_task(:environment)
  end

  it "displays detailed position information" do
    Position.create!(
      product_id: "BIT-29AUG25-CDE",
      side: "LONG",
      size: 1.0,
      entry_price: 50_000.0,
      entry_time: Time.current,
      status: "OPEN",
      day_trading: true
    )

    expect { task.execute }.to output(/Position Details/).to_stdout
    expect { task.execute }.to output(/BIT-29AUG25-CDE/).to_stdout
    expect { task.execute }.to output(/LONG/).to_stdout
    expect { task.execute }.to output(/1\.0/).to_stdout
  end

  it "handles empty positions gracefully" do
    Position.destroy_all

    expect { task.execute }.to output(/✅ No open day trading positions/).to_stdout
  end
end
