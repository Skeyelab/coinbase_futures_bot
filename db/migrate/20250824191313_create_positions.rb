class CreatePositions < ActiveRecord::Migration[8.0]
  def change
    create_table :positions do |t|
      t.string :product_id
      t.string :side
      t.decimal :size
      t.decimal :entry_price
      t.datetime :entry_time
      t.datetime :close_time
      t.string :status
      t.decimal :pnl
      t.decimal :take_profit
      t.decimal :stop_loss
      t.boolean :day_trading

      t.timestamps
    end
  end
end
