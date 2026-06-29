class AddRequestedByToPrimaryMessageGroups < ActiveRecord::Migration[7.2]
  def change
    add_column :PrimaryMessageGroups, :requested_by, :string, limit: 10
  end
end
