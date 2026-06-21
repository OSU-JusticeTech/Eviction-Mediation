class IncreaseIntakeReasonLimit < ActiveRecord::Migration[8.0]
  # Tenants can now select multiple reasons for the dispute, which are stored as
  # a comma-separated string. Widen the column so several reasons fit.
  def up
    change_column :IntakeQuestions, :Reason, :string, limit: 500, null: false
  end

  def down
    change_column :IntakeQuestions, :Reason, :string, limit: 100, null: false
  end
end
