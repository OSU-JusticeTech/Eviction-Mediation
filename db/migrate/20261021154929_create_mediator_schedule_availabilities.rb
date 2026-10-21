class CreateMediatorScheduleAvailabilities < ActiveRecord::Migration[8.0]
  def change
    create_table :mediator_schedule_availabilities do |t|
      t.integer :MediatorID, null: false
      t.integer :DayOfWeek, null: false
      t.time :StartTime, null: false
      t.time :EndTime, null: false

      t.timestamps
    end

    add_index :mediator_schedule_availabilities,
          [:MediatorID, :DayOfWeek],
          name: "index_mediator_schedule_availability"
  end
end
