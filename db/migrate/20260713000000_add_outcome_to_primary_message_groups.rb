class AddOutcomeToPrimaryMessageGroups < ActiveRecord::Migration[8.0]
  def change
    add_column :PrimaryMessageGroups, :Outcome, :string, limit: 50
  end
end
