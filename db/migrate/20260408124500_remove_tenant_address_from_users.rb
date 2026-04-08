class RemoveTenantAddressFromUsers < ActiveRecord::Migration[8.0]
  def up
    remove_column "Users", :TenantAddress, :string, limit: 255
  end

  def down
    add_column "Users", :TenantAddress, :string, limit: 255
  end
end
