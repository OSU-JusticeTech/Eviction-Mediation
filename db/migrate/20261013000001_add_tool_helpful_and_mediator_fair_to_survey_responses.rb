class AddToolHelpfulAndMediatorFairToSurveyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :survey_responses, :tool_helpful, :text
    add_column :survey_responses, :mediator_fair, :text
  end
end
