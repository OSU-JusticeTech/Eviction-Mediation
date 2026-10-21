class CreateMediatorScheduledMeetings < ActiveRecord::Migration[8.0]
  def change
    create_table :mediator_scheduled_meetings do |t|
      t.integer :MediatorID, null: false
      t.integer :ConversationID, null: false
      t.datetime :StartTime, null: false
      t.datetime :EndTime, null: false
      t.string :Status, null: false, default: "scheduled"
      t.string :ZoomLink
      
      t.timestamps
    end
    
    add_index :mediator_scheduled_meetings,
              [:MediatorID, :StartTime],
              name: "index_mediator_scheduled_meetings"
  end
end
