class AddPaperToPositions < ActiveRecord::Migration[8.1]
  def change
    add_column :positions, :paper, :boolean, default: false, null: false
  end
end
