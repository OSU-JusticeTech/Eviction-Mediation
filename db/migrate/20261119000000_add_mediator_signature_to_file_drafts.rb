class AddMediatorSignatureToFileDrafts < ActiveRecord::Migration[8.0]
  def change
    add_column :FileDrafts, :MediatorSignature, :boolean, default: false, null: false
    add_column :FileDrafts, :MediatorSignedAt, :datetime
    add_column :FileDrafts, :MediatorSignatureName, :string
    add_column :FileDrafts, :MediatorSignatureUserID, :integer
  end
end
