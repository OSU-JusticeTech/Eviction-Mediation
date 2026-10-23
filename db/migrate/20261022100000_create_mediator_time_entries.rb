class CreateMediatorTimeEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :mediator_time_entries do |t|
      t.integer :MediatorID, null: false
      t.integer :ConversationID, null: false
      t.datetime :StartedAt, null: false
      t.datetime :LastActiveAt, null: false
      t.datetime :EndedAt
      t.integer :DurationSeconds

      t.timestamps
    end

    add_index :mediator_time_entries,
              :ConversationID,
              name: "index_mediator_time_entries_on_conversation"
    add_index :mediator_time_entries,
              [:MediatorID, :EndedAt],
              name: "index_mediator_time_entries_on_mediator_open"
  end
end
