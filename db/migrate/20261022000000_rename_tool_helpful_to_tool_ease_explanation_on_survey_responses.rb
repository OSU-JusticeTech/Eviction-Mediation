class RenameToolHelpfulToToolEaseExplanationOnSurveyResponses < ActiveRecord::Migration[8.0]
  def change
    rename_column :survey_responses, :tool_helpful, :tool_ease_explanation
  end
end
