class AddMediationHelpfulToSurveyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :survey_responses, :mediation_helpful, :text
  end
end
