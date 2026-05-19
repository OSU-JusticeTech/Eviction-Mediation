class RemoveTenantAddressFromUsers < ActiveRecord::Migration[8.0]
  def up
    remove_column "Users", :TenantAddress, :string, limit: 255 if column_exists?("Users", :TenantAddress)
  end

  def down
    add_column "Users", :TenantAddress, :string, limit: 255 unless column_exists?("Users", :TenantAddress)
  end
end
