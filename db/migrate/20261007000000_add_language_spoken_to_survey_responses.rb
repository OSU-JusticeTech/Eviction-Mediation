class AddLanguageSpokenToSurveyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :survey_responses, :language_spoken, :string
  end
end
