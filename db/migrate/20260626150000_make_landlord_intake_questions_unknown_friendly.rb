class MakeLandlordIntakeQuestionsUnknownFriendly < ActiveRecord::Migration[8.0]
  def change
    change_column_null :LandlordIntakeQuestions, :DesiredOutcome, true
    change_column_null :LandlordIntakeQuestions, :AmountClaimed, true
    change_column_null :LandlordIntakeQuestions, :AcceptPaymentPlan, true
  end
end
