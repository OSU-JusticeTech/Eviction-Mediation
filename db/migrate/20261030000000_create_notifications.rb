class CreateNotifications < ActiveRecord::Migration[8.0]
  def change
    create_table :notifications do |t|
      t.integer :user_id, null: false
      t.integer :conversation_id
      t.string :event, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.string :action_path, null: false
      t.datetime :read_at
      t.timestamps
    end

    add_index :notifications, [ :user_id, :read_at ]
    add_index :notifications, [ :user_id, :created_at, :id ]
    add_foreign_key :notifications, :Users, column: :user_id, primary_key: :UserID, on_delete: :cascade
  end
end
