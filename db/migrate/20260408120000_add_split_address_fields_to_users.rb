class AddSplitAddressFieldsToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column "Users", :AddressLine1, :string, limit: 255 unless column_exists?("Users", :AddressLine1)
    add_column "Users", :AddressLine2, :string, limit: 255 unless column_exists?("Users", :AddressLine2)
    add_column "Users", :City, :string, limit: 100 unless column_exists?("Users", :City)
    add_column "Users", :State, :string, limit: 2 unless column_exists?("Users", :State)
    add_column "Users", :ZipCode, :string, limit: 10 unless column_exists?("Users", :ZipCode)

    if column_exists?("Users", :TenantAddress)
      execute <<~SQL.squish
        UPDATE [Users]
        SET [AddressLine1] = [TenantAddress]
        WHERE [TenantAddress] IS NOT NULL
          AND LTRIM(RTRIM([TenantAddress])) <> ''
          AND ([AddressLine1] IS NULL OR LTRIM(RTRIM([AddressLine1])) = '')
      SQL
    end
  end

  def down
    remove_column "Users", :ZipCode if column_exists?("Users", :ZipCode)
    remove_column "Users", :State if column_exists?("Users", :State)
    remove_column "Users", :City if column_exists?("Users", :City)
    remove_column "Users", :AddressLine2 if column_exists?("Users", :AddressLine2)
    remove_column "Users", :AddressLine1 if column_exists?("Users", :AddressLine1)
  end
end
