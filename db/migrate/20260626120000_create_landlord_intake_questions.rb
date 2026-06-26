class CreateLandlordIntakeQuestions < ActiveRecord::Migration[8.0]
  def change
    create_table :LandlordIntakeQuestions, primary_key: :LandlordIntakeID, id: :integer do |t|
      t.integer :UserID, null: false
      t.string  :Reason, limit: 500, null: false
      t.text    :LandlordDescribeCause
      t.string  :DesiredOutcome, limit: 50, null: false
      t.decimal :AmountClaimed, precision: 10, scale: 2, null: false
      t.decimal :MonthlyRent, precision: 10, scale: 2
      t.date    :DateDue
      t.boolean :AcceptPaymentPlan, null: false, default: false

      t.timestamps default: -> { 'getdate()' }
    end

    add_foreign_key :LandlordIntakeQuestions, :Users, column: :UserID, primary_key: "UserID", on_delete: :cascade
  end
end
