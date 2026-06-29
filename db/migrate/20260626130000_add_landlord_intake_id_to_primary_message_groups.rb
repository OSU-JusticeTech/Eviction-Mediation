class AddLandlordIntakeIdToPrimaryMessageGroups < ActiveRecord::Migration[8.0]
  def change
    add_column :PrimaryMessageGroups, :LandlordIntakeID, :integer
    add_foreign_key :PrimaryMessageGroups, :LandlordIntakeQuestions, column: :LandlordIntakeID, primary_key: :LandlordIntakeID
  end
end
