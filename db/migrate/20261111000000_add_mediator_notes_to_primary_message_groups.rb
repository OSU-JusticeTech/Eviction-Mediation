class AddMediatorNotesToPrimaryMessageGroups < ActiveRecord::Migration[8.0]
  def change
    add_column :PrimaryMessageGroups, :MediatorNotes, :text
  end
end
