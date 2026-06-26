class MakeIntakeQuestionsUnknownFriendly < ActiveRecord::Migration[8.0]
  def change
    change_column_null :IntakeQuestions, :BestOption, true
    change_column_null :IntakeQuestions, :Section8, true
    change_column_null :IntakeQuestions, :MoneyOwed, true
    change_column_null :IntakeQuestions, :TotalCostOrMonthly, true
  end
end
