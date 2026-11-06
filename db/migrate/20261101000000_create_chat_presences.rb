class CreateChatPresences < ActiveRecord::Migration[8.0]
  def change
    create_table :chat_presences do |t|
      t.integer :user_id, null: false
      t.integer :conversation_id, null: false
      t.string :token, limit: 36, null: false
      t.datetime :expires_at, null: false
    end
    add_index :chat_presences, [ :user_id, :token ], unique: true
    add_index :chat_presences, [ :user_id, :conversation_id, :expires_at ]
    add_foreign_key :chat_presences, :Users, column: :user_id, primary_key: :UserID, on_delete: :cascade
  end
end
