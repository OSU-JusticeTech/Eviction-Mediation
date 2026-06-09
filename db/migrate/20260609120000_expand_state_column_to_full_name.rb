class ExpandStateColumnToFullName < ActiveRecord::Migration[7.2]
  def change
    change_column :users, :State, :string, limit: 50
  end
end
