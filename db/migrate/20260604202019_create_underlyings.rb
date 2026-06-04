class CreateUnderlyings < ActiveRecord::Migration[8.1]
  def change
    create_table :underlyings do |t|
      t.string :symbol
      t.string :name
      t.string :asset_class

      t.timestamps
    end
    add_index :underlyings, :symbol, unique: true
  end
end
