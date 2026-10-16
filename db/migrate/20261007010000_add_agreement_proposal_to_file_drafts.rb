class AddAgreementProposalToFileDrafts < ActiveRecord::Migration[8.0]
  def change
    add_column :FileDrafts, :AgreementProposal, :text unless column_exists?(:FileDrafts, :AgreementProposal)
  end
end
