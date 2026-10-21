class CreateMediatorScheduleBlocks < ActiveRecord::Migration[8.0]
  def change
  create_table :mediator_schedule_blocks do |t|
    t.integer :MediatorID, null: false
    t.datetime :StartTime, null: false
    t.datetime :EndTime, null: false
    t.string :Reason

    t.timestamps
  end

  add_index :mediator_schedule_blocks,
            [:MediatorID, :StartTime],
            name: "index_mediator_schedule_blocks"
  end
end
