class AddIsSystemToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :Messages, :is_system, :boolean, default: false, null: false
  end
end
