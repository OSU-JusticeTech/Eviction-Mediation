class AddSplitAddressFieldsToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column "Users", :AddressLine1, :string, limit: 255
    add_column "Users", :AddressLine2, :string, limit: 255
    add_column "Users", :City, :string, limit: 100
    add_column "Users", :State, :string, limit: 2
    add_column "Users", :ZipCode, :string, limit: 10

    execute <<~SQL.squish
      UPDATE [Users]
      SET [AddressLine1] = [TenantAddress]
      WHERE [TenantAddress] IS NOT NULL
        AND LTRIM(RTRIM([TenantAddress])) <> ''
        AND ([AddressLine1] IS NULL OR LTRIM(RTRIM([AddressLine1])) = '')
    SQL
  end

  def down
    remove_column "Users", :ZipCode
    remove_column "Users", :State
    remove_column "Users", :City
    remove_column "Users", :AddressLine2
    remove_column "Users", :AddressLine1
  end
end
