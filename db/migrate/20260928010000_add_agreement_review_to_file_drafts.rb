class AddAgreementReviewToFileDrafts < ActiveRecord::Migration[8.0]
  def change
    add_column :FileDrafts, :AgreementTemplate, :string unless column_exists?(:FileDrafts, :AgreementTemplate)
    add_column :FileDrafts, :AgreementConversationID, :integer unless column_exists?(:FileDrafts, :AgreementConversationID)
    add_column :FileDrafts, :AgreementTerms, :text unless column_exists?(:FileDrafts, :AgreementTerms)
    add_column :FileDrafts, :AgreementVersion, :integer unless column_exists?(:FileDrafts, :AgreementVersion)
  end
end
